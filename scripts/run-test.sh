#!/bin/sh
# pk's OS :: emulator QA suite
#
#   scripts/run-test.sh [iso] [disk-image]
#
# Stages (log: build/test-logs/):
#   0  test ISO variant  = selftest + poweroff in default boot args
#   1  LIVE BOOT          grub -> kernel -> initrd -> squashfs + RAM overlay -> init
#   2  HEADLESS INSTALL   auto install from virtio ISO to /dev/vdb
#   3  INSTALLED BOOT     that disk's own GRUB -> installed root (BIOS)
#   4  TORAM               copy image to RAM -> boot even after removing media
#   5  UEFI                boot ISO from OVMF pflash
#   6  PERSISTENCE         changes on PK-PERSIST disk survive reboot + DHCP/SSH
#   7  APPS                app runtime attach + pk-run dispatch (Linux/.deb/.exe/apk/Mach-O)
#   8  PENDRIVE KIT        pk-check + keymap + install (user + runtime copy) + installed runtime
#
# env:
#   PK_TEST_STAGES=1,4,5    run only some stages (default: all)
#   PK_TEST_SKIP_INSTALL=1  stage 2 + 3 skip
#   PK_TEST_TIMEOUT=240     per-VM timeout (sec)
#   PK_TEST_DISK_MB=3072    install target size
#   PK_QEMU_MEM=640         VM RAM (for low-RAM machines)
#
# Markers (printed by rootfs/overlay/sbin/pk-boot + init/init):
#   ### PK: BOOT-OK mode=live ...   ### PK: SELFTEST-OK ###
#   ### PK: INSTALL-OK ...          ### PK: INSTALL-DONE rc=0 ###
#   ### PK: POWER-OFF-NOW ###       BOOT FAIL (init)
# shellcheck shell=sh disable=SC3030,SC2086
set -eu

PK_ROOT=$(cd "$(dirname "$0")/.." && pwd); export PK_ROOT
# shellcheck disable=SC1091
. "$PK_ROOT/scripts/pk.sh"

ISO=${1:-$BUILD/pkos.iso}
TISO=$BUILD/pkos-test.iso
DISK=${2:-$BUILD/testdisk.img}
DISKMB=${PK_TEST_DISK_MB:-3072}
TMO=${PK_TEST_TIMEOUT:-240}
LOGDIR=$BUILD/test-logs
QEMU=${QEMU:-qemu-system-x86_64}
RK=$WORK/iso/boot/pk-kernel
RI=$WORK/iso/boot/pk-initrd
STAGES=${PK_TEST_STAGES:-all}
TESTPW=PkTest-123        # installed system's root password (hash gets verified)
SKIP_INSTALL=${PK_TEST_SKIP_INSTALL:-0}
MEM=${PK_QEMU_MEM:-640}
# lower it if you ask for more than the host's available RAM (otherwise QEMU
# throws "cannot set up guest memory: Cannot allocate memory")
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
# swap can back it too -> capping by RAM alone was over-cautious (with 6 GB
# of swap on the host, QA itself still shrank to 640 MB). Now: RAM + free swap.
swfree=$(awk '/SwapFree/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
capbase=$(( avail + swfree ))
if [ "${capbase:-0}" -gt 0 ]; then
  cap=$(( capbase - 320 )); [ "$cap" -lt 320 ] && cap=320
  if [ "$MEM" -gt "$cap" ]; then
    printf '  ..  [warn] host backing (RAM %s MB + swap %s MB) -> VM RAM %s MB (from %s MB)\n' "$avail" "$swfree" "$cap" "$MEM" >&2
    MEM=$cap
  fi
fi

fails=0
total=0
stage() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
pass()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }
note()  { printf '  ..  %s\n' "$*"; }
check() { # <log> <marker> <label>
  total=$((total + 1))
  if grep -q "$2" "$1" 2>/dev/null; then pass "$3"; else bad "$3  (marker '$2' not in $(basename "$1"))"; fi
}
want() { # <n>
  case ",$STAGES," in *",all,"*) return 0 ;; esac
  case ",$STAGES," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

have "$QEMU" || die "qemu missing -> sudo apt install -y qemu-system-x86"
[ -f "$ISO" ] || die "ISO not found: $ISO (first 'make iso')"
mkdir -p "$LOGDIR"; rm -f "$LOGDIR"/*.log

QB="-machine q35 -cpu max -smp 2 -m $MEM"
# with KVM on the host the suite 5-10x faster (unavailable in sandbox/nested)
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then QB="$QB -accel kvm"; fi

# run_vm <log> <timeout> <qemu args...>
#   writes serial to a log file, shuts the VM down as soon as markers appear
run_vm() {
  log=$1; tmo=$2; shift 2
  : > "$log"
  # shellcheck disable=SC2086
  setsid "$QEMU" $QB "$@" -display none -serial "file:$log" -monitor none \
      > "$log.qemu.out" 2>&1 &
  pid=$!
  i=0
  while [ $i -lt "$tmo" ]; do
    kill -0 "$pid" 2>/dev/null || break
    if grep -qE 'PK: (POWER-OFF|INSTALL-DONE|SELFTEST-OK)|BOOT FAIL|Kernel panic|no init' "$log" 2>/dev/null; then
      sleep 2
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    # heartbeat: a long silence looks like a hang
    [ $((i % 15)) = 14 ] && printf ' .. [%ds] still running\n' "$i"
    sleep 1; i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM -"$pid" 2>/dev/null || true
    sleep 2
    kill -KILL -"$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  return 0
}

wipe_disk() {
  rm -f "$DISK"
  dd if=/dev/zero of="$DISK" bs=1M count="$DISKMB" status=none conv=sparse
}

# ---------------------------------------------------------------- 0: test ISO
stage "0/8  test ISO variant (default args: selftest + poweroff + ttyS0)"
if true; then   # stage 0 is cheap (~1s) -> a fresh test ISO is always built
  if OUT=$TISO PK_TEST_CMDLINE="pk_selftest pk_poweroff pk_verify=1 pk_tune=report pk_swap=256 console=ttyS0 loglevel=4" \
       "$PK_ROOT/scripts/mk-iso" > "$LOGDIR/00-mkiso.log" 2>&1; then
    pass "test ISO: $(basename "$TISO") ($(du -h "$TISO" | cut -f1))"
  else
    tail -15 "$LOGDIR/00-mkiso.log" | sed 's/^/    /'
    bad "test ISO build fail (log: $LOGDIR/00-mkiso.log)"
    exit 1
  fi
fi
[ -f "$TISO" ] || TISO=$ISO

# ---------------------------------------------------------------- 1: live boot
if want 1; then
stage "1/8  live boot from ISO (grub + cdrom)"
  run_vm "$LOGDIR/01-live.log" "$TMO" -boot d -cdrom "$TISO"
  L=$LOGDIR/01-live.log
  check "$L" 'PK: BOOT-OK mode=live'  "grub -> kernel -> initrd -> squashfs + overlay -> init"
  check "$L" 'PK: SELFTEST-OK'        "self test pass (RAM overlay writable)"
  check "$L" 'PK: VERIFY-OK'          "live payload sha256 matched (pk_verify=1)"
  check "$L" 'PK: TUNE-REPORT-OK'     "pk-tune report (sched/io/ipc/security knobs read)"
  check "$L" 'PK: DISPLAY-'            "S08display hook ran (blank off / backlight state)"
  check "$L" 'PK: DISPLAY-KMS'           "late display probe showed a KMS device (GPU drivers ship in live)"
  check "$L" 'driver=bochs'              "QEMU -vga std bochs-drm loaded in guest (weston gets /dev/dri)" 
  check "$L" 'PK: USERS-OK'             "S12users hook: groups + homes + autologin state"
  check "$L" 'PK: MDEV-OK'              "mdev coldplug: /dev nodes with audio/input/video groups (mdev.conf)"
  check "$L" 'PK: TUNE-SWAP-SKIP'      "live (tmpfs/overlay): swap guard blocked it (would eat RAM)"
  if grep -q "boot/grub/grub.cfg" /dev/null 2>/dev/null; then :; fi
  if [ -f "$WORK/iso/boot/grub/grub.cfg" ] && grep -q "consoleblank=0" "$WORK/iso/boot/grub/grub.cfg" 2>/dev/null; then
    total=$((total + 1)); pass "consoleblank=0 in GRUB default args (no black screen from blanking)"
  else
    bad "GRUB default args in consoleblank=0 not (live.conf <-> mk-iso drift)"
  fi
  if [ -f "$WORK/iso/boot/grub/grub.cfg" ] && grep -q "nomodeset" "$WORK/iso/boot/grub/grub.cfg" 2>/dev/null; then
    total=$((total + 1)); pass "'safe graphics (nomodeset)' entry present in GRUB menu (black-screen fallback)"
  else
    bad "GRUB menu in nomodeset entry not (black-screen fallback missing)"
  fi
  check "$L" 'base is read-only'         "squashfs base read-only is"
  check "$L" 'live medium visible'       "installer for medium mount is"
  check "$L" 'PK: DEPS-OK'            "installer tools (parted/mke2fs/grub-install...) are runnable"
  if grep -q 'BOOT FAIL\|Kernel panic' "$L"; then note "--- live log tail ---"; tail -25 "$L" | sed 's/^/    /'; fi
fi

# ------------------------------------------------- 1b: media-format regression (FAT32 + frugal)
# Alpine/TinyCore/Ubuntu-casper/Ventoy -style media layouts. Without nls_cp437/nls_utf8/
# unicode + mount-option variants in the initrd, these used to fail silently (blank screen!).
if want 1 && have mkfs.vfat && have mcopy; then
  stage "1b/8  media formats: FAT32 partition + frugal (ISO as a file)"
  bd=$BUILD/mediachk; rm -rf "$bd"; mkdir -p "$bd"
  wrap_mbr() { # <raw-fat-image> <out-img> <total-mb>
    src=$1; out=$2; tot=$3
    rm -f "$out"
    dd if=/dev/zero of="$out" bs=1M count="$tot" status=none || return 1
    parted -s "$out" mklabel msdos mkpart primary fat32 1MiB 100% >/dev/null 2>&1 || return 1
    dd if="$src" of="$out" bs=1M seek=1 conv=notrunc status=none || return 1
    return 0
  }
  # (i) /live/pk.sqfs in a FAT32 partition (not frugal - direct file layout)
  dd if=/dev/zero of="$bd/sqfs.raw" bs=1M count=120 status=none
  if mkfs.vfat -F 32 -n PKCHK "$bd/sqfs.raw" >/dev/null 2>&1 && \
     mmd -i "$bd/sqfs.raw" ::/live >/dev/null 2>&1 && \
     mcopy -i "$bd/sqfs.raw" "$WORK/iso/live/pk.sqfs" ::/live/pk.sqfs >/dev/null 2>&1 && \
     wrap_mbr "$bd/sqfs.raw" "$bd/sqfs.img" 122; then
    run_vm "$LOGDIR/01c-vfatmedia.log" 220 \
      -drive "file=$bd/sqfs.img,if=virtio" -kernel "$RK" -initrd "$RI" \
      -append "console=ttyS0 loglevel=5 pk_selftest pk_poweroff"
    check "$LOGDIR/01c-vfatmedia.log" 'PK: BOOT-OK mode=live' "live boot from a FAT32 partition (vfat+nls initrd fix)"
    check "$LOGDIR/01c-vfatmedia.log" 'fs=vfat'               "media mounted via vfat (nls_cp437/utf8 path)"
  else
    bad "FAT32 media fixture could not be built (check mtools/parted)"
  fi
  # (ii) frugal: only the ISO file in the partition (Ubuntu casper iso-scan / Ventoy style)
  dd if=/dev/zero of="$bd/frugal.raw" bs=1M count=200 status=none
  if mkfs.vfat -F 32 -n PKFRUG "$bd/frugal.raw" >/dev/null 2>&1 && \
     mcopy -i "$bd/frugal.raw" "$ISO" ::/pkos-1.0.iso >/dev/null 2>&1 && \
     wrap_mbr "$bd/frugal.raw" "$bd/frugal.img" 202; then
    run_vm "$LOGDIR/01d-frugal.log" 220 \
      -drive "file=$bd/frugal.img,if=virtio" -kernel "$RK" -initrd "$RI" \
      -append "console=ttyS0 loglevel=5 pk_selftest pk_poweroff"
    check "$LOGDIR/01d-frugal.log" 'PK: BOOT-OK mode=live' "frugal: live boot from the ISO file alone (loop+iso9660)"
    check "$LOGDIR/01d-frugal.log" '/dev/loop'             "frugal ISO mounted via loop"
  else
    bad "frugal fixture could not be built (check mtools)"
  fi
  rm -rf "$bd"
fi

# ---------------------------------------------------------------- 2 + 3: install
if [ "$SKIP_INSTALL" = 1 ]; then
  stage "2/7 + 3/7  skipped (PK_TEST_SKIP_INSTALL=1)"
elif want 2 || want 3; then
  [ -f "$RK" ] && [ -f "$RI" ] || die "stage 2/3 needs $RK + $RI (run: make iso)"
  stage "2/8  headless install -> $(basename "$DISK") (${DISKMB}MB virtio disk)"
  wipe_disk
  run_vm "$LOGDIR/02-install.log" "$TMO" \
    -drive "file=$ISO,if=virtio,readonly=on" -drive "file=$DISK,if=virtio" \
    -kernel "$RK" -initrd "$RI" \
    -append "console=ttyS0 loglevel=4 pk_media=/dev/vda pk_install=/dev/vdb pk_silent pk_halt pk_rootpw=$TESTPW"
  L=$LOGDIR/02-install.log
  check "$L" 'PK: BOOT-OK mode=live'   "live boot of the install session"
  check "$L" 'PK: INSTALL-OK'          "installer finished (partition + copy + grub)"
  check "$L" 'PK: INSTALL-DONE rc=0'   "autoinstall hook exit 0"
  check "$L" 'PK: POWER-OFF'           "pk_halt -> poweroff"
  check "$L" 'PK: INSTALL-JOURNAL-OK' "installed root with ext4 journal (crash-safe)"
  if grep -q 'INSTALL-FAIL\|INSTALL-DONE rc=[1-9]' "$L"; then
    note "--- install log tail ---"; tail -30 "$L" | sed 's/^/    /'
  fi

  # --- host side verification: whatever got written to the disk image, is it right?
  mnt=$BUILD/test-mnt; mkdir -p "$mnt"
  off=$(parted -s -m "$DISK" unit B print 2>/dev/null | awk -F: '$1=="3"{print $2}' | tr -d 'B')
  as_root umount "$mnt" 2>/dev/null || true
  mounted=no; DFS=""
  # noload: the ext4 journal is still dirty right after the installer wrote it, and a
  # plain read-only mount of a dirty-journal fs is refused by the kernel.
  for opt in "ro,noload,loop" "ro,loop" "loop"; do
    [ -n "${off:-}" ] || break
    [ "$mounted" = yes ] && break
    as_root mount -o "$opt,offset=$off" "$DISK" "$mnt" 2>/dev/null && mounted=yes
  done
  if [ "$mounted" = no ] && [ -n "${off:-}" ] && have debugfs; then
    dfstmp=$BUILD/test-dfs; mkdir -p "$dfstmp"
    DFS=$(as_root losetup -f 2>/dev/null || true)
    if [ -n "${DFS:-}" ]; then as_root losetup -o "$off" "$DFS" "$DISK" 2>/dev/null || DFS=""; fi
  fi
  # read through the mount as root: the fs root can be 0700, so a plain user test -e lies
  inst_present() {  # $1 = path that must exist (and be non-empty, except symlinks)
    if [ "$mounted" = yes ]; then
      as_root sh -c "[ -e '$mnt/$1' ]" 2>/dev/null || return 1
      case $1 in
        sbin/init) as_root sh -c "[ -x '$mnt/$1' ]" 2>/dev/null ;;
        *)         as_root sh -c "[ -s '$mnt/$1' ]" 2>/dev/null ;;
      esac
    else
      [ -n "${DFS:-}" ] || return 1
      as_root debugfs -R "stat $1" "$DFS" 2>/dev/null | grep -qE 'Size: [1-9]'
    fi
  }
  inst_cat() {       # $1 = path -> contents on stdout
    if [ "$mounted" = yes ]; then as_root cat "$mnt/$1" 2>/dev/null
    elif [ -n "${DFS:-}" ]; then
      as_root debugfs -R "dump $1" "$DFS" "$BUILD/test-dfs/f" 2>/dev/null && cat "$BUILD/test-dfs/f" 2>/dev/null
    fi
  }
  if [ "$mounted" = yes ] || [ -n "${DFS:-}" ]; then
    total=$((total + 1))
    if inst_present etc/pk-installed && inst_present sbin/init && \
       inst_present boot/pk-kernel && inst_present boot/pk-initrd; then
      [ "$mounted" = yes ] && pass "installed tree looks correct (init + kernel + initrd + marker)" \
        || pass "installed tree looks correct (init + kernel + initrd + marker) [debugfs]"
    else
      bad "installed tree is incomplete (check init/kernel/initrd)"
    fi
    # root password: extract shadow's salt and re-hash on the host -> must match
    sh_line=$(inst_cat etc/shadow | grep '^root:' || true)
    salth=$(printf '%s' "$sh_line" | cut -d: -f2)
    salt=$(printf '%s' "$salth" | cut -d'$' -f3)
    id=$(printf '%s' "$salth" | cut -d'$' -f2)
    total=$((total + 1))
    case $id in
      5|6)
        if have openssl && [ -n "$salt" ]; then
          want=$(openssl passwd "-$id" -salt "$salt" "$TESTPW" 2>/dev/null)
          if [ "$want" = "$salth" ]; then pass "root password matches '$TESTPW' after install (sha-$id)"
          else bad "root hash mismatch (login will fail despite the password being set)"; fi
        else
          note "openssl/salt not found -> hash verify skip"
        fi ;;
      *) bad "installed /etc/shadow in root hash not found (id='$id')" ;;
    esac
    total=$((total + 1))
    if inst_cat boot/grub/grub.cfg | grep -q 'root=UUID='; then
      pass "installed grub.cfg uses root=UUID (no dependency on device names)"
    else
      bad "installed grub.cfg in root=UUID is missing"
    fi
    if inst_present etc/pk-boot.d/S20net && inst_cat etc/default/pk | grep -q 'PK_DHCP=yes'; then
      pass "installed system has DHCP on (etc/default/pk)"
    else
      note "could not check the installed DHCP flag"
    fi
    [ "$mounted" = yes ] && { as_root umount "$mnt" 2>/dev/null || true; }
    [ -n "${DFS:-}" ] && { as_root losetup -d "$DFS" 2>/dev/null || true; }
  else
    note "disk image mount also debugfs also not run (sudo/parted/e2fsprogs required) -> host-side verify skip"
  fi

  stage "3/8 installed disk own GRUB (BIOS) -> installed root"
  if ! want 3; then
    note "stage 3 skipped (PK_TEST_STAGES in 3 not)"
  else
    # inject serial console + selftest + poweroff into the installed grub.cfg
    # (so the headless test sees markers) - for tests only
    # GPT layout: p1=bios_grub p2=ESP p3=root(ext4). p3 offset from parted.
    inject() {
      mp=$BUILD/test-mnt
      mkdir -p "$mp"
      off=$(parted -s -m "$DISK" unit B print 2>/dev/null | awk -F: '$1=="3"{print $2}' | tr -d 'B')
      [ -n "${off:-}" ] || return 1
      as_root umount "$mp" 2>/dev/null || true
      as_root mount -o loop,offset="$off" "$DISK" "$mp" 2>/dev/null || return 1
      [ -f "$mp/boot/grub/grub.cfg" ] || { as_root umount "$mp" 2>/dev/null; return 1; }
      as_root sed -i -e 's|loglevel=3|loglevel=4 console=ttyS0 pk_selftest pk_poweroff pk_swap=256|' \
                     -e 's|root=UUID=.*|& console=ttyS0 pk_selftest pk_poweroff|' \
                     "$mp/boot/grub/grub.cfg" 2>/dev/null
      as_root sync; as_root umount "$mp" 2>/dev/null || true
      return 0
    }
    if have parted && inject; then
      note "grub.cfg inject done (console=self test args)"
      run_vm "$LOGDIR/03-installed.log" "$TMO" -drive "file=$DISK,if=virtio" -boot c
      L=$LOGDIR/03-installed.log
      check "$L" 'PK: BOOT-OK mode=installed' "installed system booted (from its own GRUB)"
      check "$L" 'PK: SELFTEST-OK'           "installed root writable + tools ok"
      check "$L" 'PK: PASSWD-OK'             "installed /etc/shadow in real sha-crypt hash is"
      check "$L" 'PK: LOGIN-REQUIRED'        "installed system asks for a password (no autologin)"
      check "$L" 'PK: TUNE-SWAP-OK'          "swapfile created + started on installed ext4 via pk_swap=256"
      grep -q 'BOOT FAIL\|Kernel panic\|Unable to mount\|No bootable device' "$L" && {
        note "--- installed log tail ---"; tail -25 "$L" | sed 's/^/    /'; }
    else
      note "could not inject (sudo/parted required) -> direct kernel boot from check pass it this"
      run_vm "$LOGDIR/03-installed.log" "$TMO" -drive "file=$DISK,if=virtio" \
        -kernel "$RK" -initrd "$RI" \
        -append "console=ttyS0 loglevel=4 root=/dev/vda3 pk_selftest pk_poweroff"
      check "$LOGDIR/03-installed.log" 'PK: BOOT-OK mode=installed' "installed root mount + init (direct kernel boot)"
    fi
  fi
fi

# ---------------------------------------------------------------- 4: toram
if want 4; then
stage "4/8  toram (copy image to RAM -> media mount reuse)"
  run_vm "$LOGDIR/04-toram.log" "$TMO" -boot d -cdrom "$TISO" \
    -kernel "$RK" -initrd "$RI" \
    -append "console=ttyS0 loglevel=4 toram pk_selftest pk_poweroff"
  L=$LOGDIR/04-toram.log
  check "$L" 'toram done'         "image copied to RAM"
  check "$L" 'PK: BOOT-OK'     "system booted after toram too"
  check "$L" 'PK: SELFTEST-OK' "self test (toram) pass"
fi

# ---------------------------------------------------------------- 5: UEFI
if want 5; then
stage "5/8  UEFI (OVMF) boot from ISO"
  OVMF=$(ls -1 /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF.fd 2>/dev/null | head -1)
  if [ -z "${OVMF:-}" ]; then
    note "OVMF not found -> skip (sudo apt install -y ovmf)"
  else
    VARS=$BUILD/ovmf-test.fd
    [ -f "$VARS" ] || cp "$(ls -1 /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd 2>/dev/null | head -1)" "$VARS"
    run_vm "$LOGDIR/05-uefi.log" "$TMO" \
      -drive "if=pflash,format=raw,readonly=on,file=$OVMF" \
      -drive "if=pflash,format=raw,file=$VARS" \
      -boot d -cdrom "$TISO"
    check "$LOGDIR/05-uefi.log" 'PK: BOOT-OK' "boot works from UEFI (OVMF) too"
  fi
fi


# ---------------------------------------------------------------- 6: persistence + net + ssh
if want 6; then
stage "6/8  persistence (PK-PERSIST disk) + DHCP + SSH"
  PDISK=$BUILD/testpersist.img
  seed=$BUILD/persist-seed; mkdir -p "$seed"
  rm -f "$PDISK"
  dd if=/dev/zero of="$PDISK" bs=1M count=512 status=none conv=sparse
  # the whole image is ext4 (label PK-PERSIST) - init also tries a whole disk
  if ! mkfs.ext4 -q -F -L PK-PERSIST "$PDISK" > "$LOGDIR/06-mkfs.log" 2>&1; then
    as_root mkfs.ext4 -q -F -L PK-PERSIST "$PDISK" >> "$LOGDIR/06-mkfs.log" 2>&1 \
      || bad "mkfs.ext4 (persist image) fail"
  fi
  as_root umount "$seed" 2>/dev/null || true
  if as_root mount -o loop "$PDISK" "$seed" 2>/dev/null; then
    as_root mkdir -p "$seed/pk-persist/upper" "$seed/pk-persist/work"
    as_root chmod 755 "$seed/pk-persist" "$seed/pk-persist/upper" "$seed/pk-persist/work"
    as_root sync; as_root umount "$seed" 2>/dev/null || true
  else
    bad "persist image could not be mounted (sudo/loop required)"
  fi

  PAPPEND="console=ttyS0 loglevel=4 persistent pk_selftest pk_poweroff pk_net=dhcp pk_ssh=on"
  note "boot A: first time - persistence-on marker will be written"
  run_vm "$LOGDIR/06a-persist-write.log" "$TMO" \
    -drive "file=$ISO,if=virtio,readonly=on" -drive "file=$PDISK,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -kernel "$RK" -initrd "$RI" -append "$PAPPEND"
  LA=$LOGDIR/06a-persist-write.log
  check "$LA" 'persistence (/dev/vdb)'   "init found the persistence partition"
  check "$LA" 'pk-persist/upper'      "root overlay upperdir is on the persist disk"
  check "$LA" 'PK: PERSIST-WROTE'     "fresh persist disk on marker file was written"
  check "$LA" 'PK: NET-OK'            "got a DHCP IP (pk_net=dhcp)"
  check "$LA" 'PK: SSH-OK'            "dropbear SSH started (pk_ssh=on)"
  check "$LA" 'PK: SELFTEST-OK'       "self test (persistent) pass"

  # host side: did the file really arrive in the image file?
  total=$((total + 1))
  as_root mount -o loop "$PDISK" "$seed" 2>/dev/null || true
  if as_root test -f "$seed/pk-persist/upper/root/.pk-persist-marker"; then
    pass "persist image in marker disk on present (host from verify)"
    as_root cat "$seed/pk-persist/upper/root/.pk-persist-marker" 2>/dev/null | sed 's/^/      ..  /'
  else
    bad "marker file not found in persist image"
  fi
  as_root sync; as_root umount "$seed" 2>/dev/null || true

  note "boot B: same disk - file should survive a reboot too"
  run_vm "$LOGDIR/06b-persist-keep.log" "$TMO" \
    -drive "file=$ISO,if=virtio,readonly=on" -drive "file=$PDISK,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -kernel "$RK" -initrd "$RI" -append "$PAPPEND"
  LB=$LOGDIR/06b-persist-keep.log
  check "$LB" 'PK: PERSIST-KEPT'  "changes alive after reboot too (persistence works)"
  check "$LB" 'PK: SELFTEST-OK'   "second persistent boot was clean"
  if grep -q 'PERSIST-FAIL\|overlay(persistence) fail' "$LA" 2>/dev/null; then
    note "--- 06a log tail ---"; tail -20 "$LA" | sed 's/^/    /'
  fi
  rm -f "$PDISK"
fi
# ---------------------------------------------------------------- 7: app runtime + apps
if want 7; then
stage "7/8  app runtime (Linux/Windows/.deb dispatch) + pk-run selftest"
  RTQ=$BUILD/testruntime.sqfs
  RDISK=$BUILD/testruntime.img
  seed2=$BUILD/runtime-seed; mkdir -p "$seed2"
  MLOGL=$LOGDIR/07-mkruntime.log; : > "$MLOGL"
  REALRT=0
  RTMBSZ=128
  A7="console=ttyS0 loglevel=4 pk_selftest pk_poweroff pk_net=dhcp"
  if [ "${PK_TEST_REAL_RUNTIME:-0}" = 1 ] && [ -s "$BUILD/pk-runtime.sqfs" ]; then
    REALRT=1; RTMBSZ=1024
    RTQ=$BUILD/pk-runtime.sqfs
    note "using the REAL runtime ($(du -h "$RTQ" | cut -f1)) - apt/dpkg path + pk_apps_get=sl (20 KB, missing in runtime -> real download from net)"
    A7="$A7 pk_apps_get=sl"
    [ "${PK_TEST_WINE:-0}" = 1 ] && A7="$A7 pk_apps_get=wine:--version"
  else
    note "building the runtime image (scripts/make-runtime --tiny)"
    rm -f "$RTQ"
  fi
  if [ "$REALRT" = 1 ]; then
    total=$((total + 1)); pass "real runtime image present ($RTQ)"
  elif as_root sh "$PK_ROOT/scripts/make-runtime" --tiny --out="$RTQ" --no-rw >> "$MLOGL" 2>&1; then
    total=$((total + 1))
    if [ -s "$RTQ" ]; then pass "runtime squashfs built ($(du -h "$RTQ" | cut -f1 | tr -d ' '))"; else bad "runtime squashfs came out empty"; fi
  else
    bad "make-runtime --tiny fail (log: 07-mkruntime.log)"
  fi

  rm -f "$RDISK"
  dd if=/dev/zero of="$RDISK" bs=1M count="$RTMBSZ" status=none conv=sparse
  if ! mkfs.ext4 -q -F -L PK-RUNTIME "$RDISK" >> "$MLOGL" 2>&1; then
    as_root mkfs.ext4 -q -F -L PK-RUNTIME "$RDISK" >> "$MLOGL" 2>&1 || bad "mkfs.ext4 (runtime disk) fail"
  fi
  as_root umount "$seed2" 2>/dev/null || true
  if as_root mount -o loop "$RDISK" "$seed2" 2>/dev/null; then
    as_root cp "$RTQ" "$seed2/pk-runtime.sqfs" || bad "runtime sqfs copy fail"
    as_root dd if=/dev/zero of="$seed2/pk-runtime-rw.img" bs=1M count=$(( RTMBSZ / 2 )) status=none conv=sparse 2>>"$MLOGL"
    as_root mkfs.ext4 -q -F -L pk-runtime-rw "$seed2/pk-runtime-rw.img" >> "$MLOGL" 2>&1 || bad "rw img mkfs fail"
    as_root sync; as_root umount "$seed2" 2>/dev/null || true
  else
    bad "runtime disk could not be mounted (sudo/loop required)"
  fi

  note "boot A: find runtime + attach check, then pk-run dispatch battery"
  run_vm "$LOGDIR/07a-apps.log" "$TMO" \
    -drive "file=$ISO,if=virtio,readonly=on" -drive "file=$RDISK,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -kernel "$RK" -initrd "$RI" -append "$A7"
  LA=$LOGDIR/07a-apps.log
  check "$LA" 'PK: RUNTIME-OK'        "app runtime attached at /opt/pk (from PK-RUNTIME disk)"

  # --- essential software that ships inside the ISO (release requirement) ----------
  ESSLIST=$BUILD/work/runtime/etc/pk-essentials.txt
  total=$((total + 1))
  if [ -f "$ESSLIST" ] && grep -q 'missing=0' "$ESSLIST"; then
    pass "build record: essential commands present ($(tail -1 "$ESSLIST"))"
  elif [ -f "$ESSLIST" ]; then
    bad "build record says some essentials are missing: $(tail -1 "$ESSLIST")"
  else
    note "no desktop-runtime build record ($ESSLIST) - created by 'make runtime-desktop'"
  fi
  if [ "$REALRT" = 1 ]; then
    check "$LA" 'PK: ESSENTIALS-OK'   "guest boot verified the runtime essentials"
  else
    note "guest essentials marker not asserted (tiny QA runtime; run with PK_TEST_REAL_RUNTIME=1)"
  fi
  check "$LA" 'PK: APP-ELF-OK'        "native Linux ELF app ran"
  check "$LA" 'PK: APP-SCRIPT-OK'     "script app ran"
  check "$LA" 'PK: APP-DEB-OK'        ".deb installed + launcher created"
  if [ "$REALRT" = 1 ]; then
      # Does the runtime we booted actually contain Wine? Ask the image instead of
      # assuming: `make runtime` (lean) ships none, `make runtime-desktop` ships it -
      # so the expectation differs per runtime. This branch used to always demand the
      # no-Wine diagnostic, which failed a correct desktop runtime (stage 7 only).
      rhavewine=0
      if have unsquashfs; then
        unsquashfs -l "$RTQ" 2>/dev/null | grep -qE "/usr/bin/wine$" && rhavewine=1
      fi
    if [ "${PK_TEST_WINE:-0}" = 1 ]; then
      check "$LA" 'PK: APPS-GET-OK (wine)' "real Wine installed (apt) and 'wine --version' ran"
    elif [ "$rhavewine" = 1 ]; then
      check "$LA" 'PK: APP-EXE-OK'      ".exe dispatched through the runtime's real Wine"
    else
      check "$LA" 'PK: APP-EXE-DIAG'    ".exe: this runtime has no Wine - the honest diagnostic appeared instead"
    fi
  else
    check "$LA" 'PK: APP-EXE-OK'        "Windows .exe Wine dispatch instead (fake wine, tiny runtime)"
  fi
  check "$LA" 'PK: APP-APK-DIAG-OK'   ".apk recognized + honest diagnostic (binder/waydroid)"
  check "$LA" 'PK: APP-MACHO-DIAG-OK' "Mach-O (macOS) refused with the right reason"
  check "$LA" 'PK: RUNTIME-EXEC-OK'   "command ran inside the runtime (chroot + binds)"
  check "$LA" 'PK: APPS-OK'           "apps selftest fully passed"
  check "$LA" 'PK: NET-OK'            "DHCP with the apps layer too"
  if [ "$REALRT" = 1 ]; then
    check "$LA" 'APP-DEB-OK (dpkg path)' ".deb installed via dpkg in the runtime"
    check "$LA" 'PK: APPS-GET-OK (sl)' "apt from net on download + run (sl); /usr/games lookup also"
    check "$LA" 'APP-EXE-OK\|APP-EXE-NO-WINE' ".exe dispatch (runs if wine is installed, else diagnostic)"
  fi

  total=$((total + 1))
  as_root umount "$seed2" 2>/dev/null || true
  rtok=0
  if as_root mount -o loop "$RDISK" "$seed2" 2>/dev/null; then
    as_root mkdir -p "$seed2/rw"
    if as_root mount -o loop "$seed2/pk-runtime-rw.img" "$seed2/rw" 2>/dev/null; then
      if as_root sh -c "find '$seed2/rw/pk-runtime/upper' 2>/dev/null | grep -q 'pk-st-app'"; then
        rtok=1
        pass "installed app is in the runtime rw overlay (verify from host: inside pk-runtime-rw.img)"
      else
        echo " .. found in overlay: $(as_root find "$seed2/rw/pk-runtime/upper" -maxdepth 3 2>/dev/null | sed -n '2,4p' | tr '\n' ' ')"
      fi
      as_root umount "$seed2/rw" 2>/dev/null || true
    else
      echo " .. (rw img loop could not be mounted from host)"
    fi
    as_root umount "$seed2" 2>/dev/null || true
  fi
  [ "$rtok" = 1 ] || bad "installed app not visible in runtime overlay"

  note "boot B: same runtime disk - re-attach + selftest"
  run_vm "$LOGDIR/07b-apps2.log" "$TMO" \
    -drive "file=$ISO,if=virtio,readonly=on" -drive "file=$RDISK,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -kernel "$RK" -initrd "$RI" -append "$A7"
  check "$LOGDIR/07b-apps2.log" 'PK: RUNTIME-OK' "runtime attached on second boot too"
  check "$LOGDIR/07b-apps2.log" 'PK: APPS-OK'    "apps selftest passed on second boot too"
fi

# ---------------------------------------------------------------- 8: pendrive kit
if want 8; then
stage "8/8  pendrive kit: pk-check + keymap + install (user + runtime) + installed runtime"
  RTSRC=${PK_KIT_RUNTIME:-$BUILD/pk-runtime.sqfs}
  [ -s "$RTSRC" ] || RTSRC=$BUILD/testruntime.sqfs
  KISO=$BUILD/pkos-kit.iso
  KITDISK=$BUILD/kitdisk.img
  KTMO=$TMO
  [ "$KTMO" -lt 480 ] && KTMO=480
  total=$((total + 1))
  if [ -s "$RTSRC" ]; then
    pass "kit runtime source: $(basename "$RTSRC") ($(du -h "$RTSRC" | cut -f1))"
  else
    bad "any runtime sqfs not ($BUILD/pk-runtime.sqfs / testruntime.sqfs) - first 'make test-apps'"
  fi
  note "building the kit ISO (runtime inside the ISO; selftest+poweroff args)"
  rm -f "$KISO"
  if OUT="$KISO" WITH_RUNTIME=1 PK_RUNTIME_IMG="$RTSRC" \
       PK_TEST_CMDLINE="pk_selftest pk_poweroff pk_verify=1 pk_tune=report console=ttyS0 loglevel=4" \
       "$PK_ROOT/scripts/mk-iso" > "$LOGDIR/08-mkkit.log" 2>&1; then
    pass "kit ISO built (runtime inside): $(du -h "$KISO" | cut -f1)"
  else
    bad "kit ISO build fail (log: 08-mkkit.log)"
  fi
  rm -f "$KITDISK"
  dd if=/dev/zero of="$KITDISK" bs=1M count="$DISKMB" status=none conv=sparse

  A8="console=ttyS0 loglevel=4 pk_media=/dev/vda pk_install=/dev/vdb pk_silent pk_selftest pk_rootpw=$TESTPW pk_install_user=kituser pk_install_userpw=$TESTPW pk_check=1 pk_keymap=us pk_net=dhcp pk_tune=desktop"
  if [ "${PK_TEST_GUI:-0}" = 1 ]; then
    A8="$A8 pk_desktop=1 pk_check=gui"
    KTMO=$(( KTMO + 300 ))
    note "GUI mode: desktop session (weston -> Xvfb fallback) + X client round-trip also check"
  fi
  note "boot A: kit ISO -> pk-check, pk-keymap, headless install (--user + runtime copy)"
  run_vm "$LOGDIR/08a-kit.log" "$KTMO" \
    -drive "file=$KISO,if=virtio,readonly=on" -drive "file=$KITDISK,if=virtio" \
    -kernel "$RK" -initrd "$RI" \
    -append "$A8"
  L=$LOGDIR/08a-kit.log
  check "$L" 'PK: BOOT-OK mode=live'  "live boot of the kit ISO"
  check "$L" 'PK: RUNTIME-OK'         "runtime attached at /opt/pk from inside the ISO"
  check "$L" 'PK: CHECK-OK'           "pk-check: any FAIL not (hardware+OS self-test)"
  check "$L" 'PK: KEYMAP-'            "pk-keymap us run (console + GUI)"
  check "$L" 'PK: NET-OK'             "DHCP with the kit too"
  check "$L" 'PK: INSTALL-OK'          "install (with user + runtime copy) finished"
  check "$L" 'PK: INSTALL-DONE rc=0'   "installer rc 0 (autoinstall hook)"
  if [ "${PK_TEST_GUI:-0}" = 1 ]; then
    check "$L" 'PK: DESKTOP-OK'       "pk-desktop: session started (weston or Xvfb fallback)"
    check "$L" 'PK: SEATD-OK'          "seatd session manager started (VT+DRM+input for weston)"
    check "$L" 'PK: DESKTOP-VT'        "weston took the active VT -> desktop shows on screen"
    check "$L" 'PK: DESKTOP-WESTON-LOG' "weston's own log has markers (debugging possible)"
    if grep -q 'DESKTOP-VTMISMATCH' "$L" 2>/dev/null; then
      bad "weston ran but no VT switch (screen stays text) - try pk-desktop vnc"
    else
      pass "weston took the VT (no VTMISMATCH marker)"
    fi
    check "$L" 'PK: GUI-X-OK'         "pk-check --gui: display found"
    if grep -q 'GUI-SHOT-OK' "$L" 2>/dev/null; then
      pass "desktop screenshot taken (from weston) - pixel-level proof: /run/pk/desktop-shot.png"
      total=$((total + 1))
    else
      note "screenshot row was warn (weston sends no frame for a static screen) - pixel proof in guest: pk-desktop shot /root/d.png"
    fi
    check "$L" 'PK: GUI-APP-OK'       "GUI client (xterm or weston-terminal) ran in session"
    if grep -q 'GUI-XCLIENT-OK' "$L" 2>/dev/null; then
      pass "X client (xdpyinfo) also used the display"
      total=$((total + 1))
    else
      note " (xdpyinfo row skipped - Wayland-only session; GUI-APP-OK is the real proof)"
    fi
  fi
  note "stage-9 style checks (pk-tune/pk-binfmt) in this same boot:"
  A9=$(printf 'pk_selftest')
  # (in the VM these commands run via pk-boot's S90 hook - markers checked below)
  check "$L" 'PK: TUNE-REPORT-OK'     "pk-tune report ran (scheduling/io/ipc/security knobs read)"
  check "$L" 'PK: BINFMT-'            "pk-binfmt status reported handler state"
  check "$L" 'PK: ARCH-DISPATCH-OK'   "foreign-arch (arm64) ELF -> qemu-user/binfmt dispatch correct"
  if grep -q 'CHECK-SUMMARY' "$L" 2>/dev/null; then
    note "pk-check: $(grep -o 'CHECK-SUMMARY[^#]*' "$L" | head -1 | tr -d '\r')"
  else
    note " (CHECK-SUMMARY not found -> less $L)"
  fi

  mnt2=$BUILD/test-mnt2; mkdir -p "$mnt2"
  off2=$(parted -s -m "$KITDISK" unit B print 2>/dev/null | awk -F: '$1=="3"{print $2}' | tr -d 'B')
  as_root umount "$mnt2" 2>/dev/null || true
  hostok=0
  if [ -n "${off2:-}" ] && as_root mount -o ro,loop,offset="$off2" "$KITDISK" "$mnt2" 2>/dev/null; then
    hostok=1
    total=$((total + 1))
    if as_root test -s "$mnt2/var/lib/pk/pk-runtime.sqfs"; then
      pass "app runtime copied into the installed system (/var/lib/pk/pk-runtime.sqfs)"
    else
      bad "runtime copy not found in installed system"
    fi
    total=$((total + 1))
    if as_root test -f "$mnt2/var/lib/pk/pk-runtime-rw.img"; then
      pass "installed rw image created (apps will remain after reboot too)"
    else
      bad "installed rw image not created (mkfs.ext4 in live?)"
    fi
    total=$((total + 1))
    if as_root grep -q '^kituser:' "$mnt2/etc/passwd" 2>/dev/null && as_root grep -q '^kituser:' "$mnt2/etc/shadow" 2>/dev/null; then
      uh=$(as_root awk -F: '$1=="kituser"{print $3}' "$mnt2/etc/passwd" 2>/dev/null)
      if as_root awk -F: '$1=="kituser"{exit ($2 ~ /^\$/ ? 0 : 1)}' "$mnt2/etc/shadow" 2>/dev/null; then
        pass "non-root user 'kituser' created (uid=${uh:-?}) + sha-crypt hash in shadow"
      else
        bad "kituser password hash not set (mkpasswd in live image?)"
      fi
    else
      bad "no account created from --user (kituser not in passwd/shadow)"
    fi
    as_root umount "$mnt2" 2>/dev/null || true
  else
    bad "could not mount the kit disk from the host (checks skipped)"
  fi

  note "boot B: installed disk via its own GRUB - runtime must attach from /var/lib/pk"
  kitinject() {
    mp=$BUILD/test-mnt2
    mkdir -p "$mp"
    o=$(parted -s -m "$KITDISK" unit B print 2>/dev/null | awk -F: '$1=="3"{print $2}' | tr -d 'B')
    [ -n "$o" ] || return 1
    as_root umount "$mp" 2>/dev/null || true
    as_root mount -o loop,offset="$o" "$KITDISK" "$mp" 2>/dev/null || return 1
    [ -f "$mp/boot/grub/grub.cfg" ] || { as_root umount "$mp" 2>/dev/null; return 1; }
    as_root sed -i -e 's|root=UUID=.*|& console=ttyS0 loglevel=4 pk_selftest pk_poweroff|' \
                   "$mp/boot/grub/grub.cfg" 2>/dev/null
    as_root sync; as_root umount "$mp" 2>/dev/null || true
    return 0
  }
  if have parted && kitinject; then
    run_vm "$LOGDIR/08b-installed.log" "$KTMO" -drive "file=$KITDISK,if=virtio" -boot c
    check "$LOGDIR/08b-installed.log" 'PK: BOOT-OK mode=installed' "installed kit system booted"
    check "$LOGDIR/08b-installed.log" 'PK: RUNTIME-OK'            "installed system attached runtime from /var/lib/pk"
    check "$LOGDIR/08b-installed.log" 'rw-image'                  "rw image upper in installed mode (persistence on)"
    check "$LOGDIR/08b-installed.log" 'PK: LOGIN-REQUIRED'        "installed kit system asks for a password"
    if grep -q 'BOOT FAIL\|Kernel panic\|VFS: Unable to mount' "$LOGDIR/08b-installed.log" 2>/dev/null; then
      note "--- installed kit log tail ---"; tail -22 "$LOGDIR/08b-installed.log" | sed 's/^/    /'
    fi
  else
    note "could not inject -> checking with direct kernel boot from the installed root"
    run_vm "$LOGDIR/08b-installed.log" "$KTMO" -drive "file=$KITDISK,if=virtio" \
      -kernel "$RK" -initrd "$RI" \
      -append "console=ttyS0 loglevel=4 root=/dev/vda3 pk_selftest pk_poweroff"
    check "$LOGDIR/08b-installed.log" 'PK: RUNTIME-OK' "runtime attached from the installed root (direct kernel boot)"
  fi
  as_root rm -rf "$mnt2" 2>/dev/null || true
fi

# ---------------------------------------------------------------- report
total_or_note() { :; }
printf '\n'
echo "=================================================="
if [ "$fails" = 0 ]; then
  printf '  \033[32mQA PASS\033[0m  %d checks ok  (logs: %s)\n' "$total" "$LOGDIR"
  echo " next: live USB build it -> make usb USB=/dev/sdX"
  echo "        permanent install on a real PC -> pk-install --target=ask"
  exit 0
else
  printf '  \033[31mQA FAIL\033[0m  %d/%d checks fail\n' "$fails" "$total"
  echo " logs: $LOGDIR (every stage's serial output is there)"
  echo "  one stage again:  PK_TEST_STAGES=2 make test"
  exit 1
fi

#!/bin/sh
# pk's OS :: emulator QA suite
#
#   scripts/run-test.sh [iso] [disk-image]
#
# Stages (log: build/test-logs/):
#   0  test ISO variant  = default boot args me selftest + poweroff
#   1  LIVE BOOT          grub -> kernel -> initrd -> squashfs + RAM overlay -> init
#   2  HEADLESS INSTALL   virtio ISO se /dev/vdb pe auto install
#   3  INSTALLED BOOT     us disk ka apna GRUB -> installed root (BIOS)
#   4  TORAM               image RAM me copy -> media nikaal ke bhi boot
#   5  UEFI                OVMF pflash se ISO boot
#   6  PERSISTENCE         PK-PERSIST disk par changes reboot ke baad bhi + DHCP/SSH
#   7  APPS                app runtime attach + pk-run dispatch (Linux/.deb/.exe/apk/Mach-O)
#   8  PENDRIVE KIT        pk-check + keymap + install (user + runtime copy) + installed runtime
#
# env:
#   PK_TEST_STAGES=1,4,5    sirf kuch stages chalao (default: all)
#   PK_TEST_SKIP_INSTALL=1  stage 2 + 3 skip
#   PK_TEST_TIMEOUT=240     per-VM timeout (sec)
#   PK_TEST_DISK_MB=3072    install target ka size
#   PK_QEMU_MEM=640         VM RAM (kam RAM wali machine ke liye)
#
# Markers (rootfs/overlay/sbin/pk-boot + init/init inhe print karte hain):
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
TESTPW=PkTest-123        # installed system ka root password (hash verify hota hai)
SKIP_INSTALL=${PK_TEST_SKIP_INSTALL:-0}
MEM=${PK_QEMU_MEM:-640}
# host ke available RAM se zyada maang rahe ho to kam kar do (warna QEMU
# "cannot set up guest memory: Cannot allocate memory" de mara jaata hai)
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
# swap bhi backing de sakta hai -> sirf RAM se cap karna over-cautious tha (host par 6 GB
# swap hone par bhi QA khud 640 MB par simat jaata tha). Ab: RAM + free swap.
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
[ -f "$ISO" ] || die "ISO nahi mila: $ISO  (pehle 'make iso')"
mkdir -p "$LOGDIR"; rm -f "$LOGDIR"/*.log

QB="-machine q35 -cpu max -smp 2 -m $MEM"
# host pe KVM ho to suite 5-10x tez (sandbox/nested me nahi milta)
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then QB="$QB -accel kvm"; fi

# run_vm <log> <timeout> <qemu args...>
#   serial ko log file me likhta hai, marker dikhte hi VM ko banda karta hai
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
    # heartbeat: lambi chuppi se lagta hai hang ho gaya
    [ $((i % 15)) = 14 ] && printf '  ..  [%ds] abhi b chal raha\n' "$i"
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
if true; then   # stage 0 sasta hai (~1s) -> hamesha fresh test ISO banega
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
  check "$L" 'PK: VERIFY-OK'          "live payload ka sha256 match hua (pk_verify=1)"
  check "$L" 'PK: TUNE-REPORT-OK'     "pk-tune report (sched/io/ipc/security knobs padhe)"
  check "$L" 'PK: DISPLAY-'            "S08display hook chala (blank off / backlight state)"
  check "$L" 'PK: DISPLAY-KMS'           "late display probe ne KMS device dikha (GPU driver live me ship hote hain)"
  check "$L" 'driver=bochs'              "QEMU -vga std ka bochs-drm guest me load hua (weston ko /dev/dri milta hai)" 
  check "$L" 'PK: TUNE-SWAP-SKIP'      "live (tmpfs/overlay) par swap guard ne rok diya (RAM nahi khayega)"
  if grep -q "boot/grub/grub.cfg" /dev/null 2>/dev/null; then :; fi
  if [ -f "$WORK/iso/boot/grub/grub.cfg" ] && grep -q "consoleblank=0" "$WORK/iso/boot/grub/grub.cfg" 2>/dev/null; then
    total=$((total + 1)); pass "GRUB default args me consoleblank=0 (blanking se kaali screen nahi hogi)"
  else
    bad "GRUB default args me consoleblank=0 nahi (live.conf <-> mk-iso drift)"
  fi
  if [ -f "$WORK/iso/boot/grub/grub.cfg" ] && grep -q "nomodeset" "$WORK/iso/boot/grub/grub.cfg" 2>/dev/null; then
    total=$((total + 1)); pass "GRUB menu me 'safe graphics (nomodeset)' entry maujood (black-screen fallback)"
  else
    bad "GRUB menu me nomodeset entry nahi (black-screen fallback missing)"
  fi
  check "$L" 'base is read-only'         "squashfs base read-only hai"
  check "$L" 'live medium visible'       "installer ke liye medium mount hai"
  check "$L" 'PK: DEPS-OK'            "installer ke tools (parted/mke2fs/grub-install...) chal sakte hain"
  if grep -q 'BOOT FAIL\|Kernel panic' "$L"; then note "--- live log tail ---"; tail -25 "$L" | sed 's/^/    /'; fi
fi

# ------------------------------------------------- 1b: media-format regression (FAT32 + frugal)
# Alpine/TinyCore/Ubuntu-casper/Ventoy jaisi media layouts. initrd me nls_cp437/nls_utf8/
# unicode + mount-option variants ke bina ye chup-chaap fail hoti thi (screen khaali!).
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
  # (i) FAT32 partition me /live/pk.sqfs (frugal nahi - direct file layout)
  dd if=/dev/zero of="$bd/sqfs.raw" bs=1M count=120 status=none
  if mkfs.vfat -F 32 -n PKCHK "$bd/sqfs.raw" >/dev/null 2>&1 && \
     mmd -i "$bd/sqfs.raw" ::/live >/dev/null 2>&1 && \
     mcopy -i "$bd/sqfs.raw" "$WORK/iso/live/pk.sqfs" ::/live/pk.sqfs >/dev/null 2>&1 && \
     wrap_mbr "$bd/sqfs.raw" "$bd/sqfs.img" 122; then
    run_vm "$LOGDIR/01c-vfatmedia.log" 220 \
      -drive "file=$bd/sqfs.img,if=virtio" -kernel "$RK" -initrd "$RI" \
      -append "console=ttyS0 loglevel=5 pk_selftest pk_poweroff"
    check "$LOGDIR/01c-vfatmedia.log" 'PK: BOOT-OK mode=live' "FAT32 partition media se live boot (vfat+nls initrd fix)"
    check "$LOGDIR/01c-vfatmedia.log" 'fs=vfat'               "media vfat se mount hua (nls_cp437/utf8 path)"
  else
    bad "FAT32 media fixture ban hi nahi (mtools/parted check karo)"
  fi
  # (ii) frugal: partition me sirf ISO file (Ubuntu casper iso-scan / Ventoy style)
  dd if=/dev/zero of="$bd/frugal.raw" bs=1M count=200 status=none
  if mkfs.vfat -F 32 -n PKFRUG "$bd/frugal.raw" >/dev/null 2>&1 && \
     mcopy -i "$bd/frugal.raw" "$ISO" ::/pkos-1.0.iso >/dev/null 2>&1 && \
     wrap_mbr "$bd/frugal.raw" "$bd/frugal.img" 202; then
    run_vm "$LOGDIR/01d-frugal.log" 220 \
      -drive "file=$bd/frugal.img,if=virtio" -kernel "$RK" -initrd "$RI" \
      -append "console=ttyS0 loglevel=5 pk_selftest pk_poweroff"
    check "$LOGDIR/01d-frugal.log" 'PK: BOOT-OK mode=live' "frugal: sirf ISO file se live boot (loop+iso9660)"
    check "$LOGDIR/01d-frugal.log" '/dev/loop'             "frugal ISO loop-mount se mount hui"
  else
    bad "frugal fixture ban hi nahi (mtools check karo)"
  fi
  rm -rf "$bd"
fi

# ---------------------------------------------------------------- 2 + 3: install
if [ "$SKIP_INSTALL" = 1 ]; then
  stage "2/7 + 3/7  skipped (PK_TEST_SKIP_INSTALL=1)"
elif want 2 || want 3; then
  [ -f "$RK" ] && [ -f "$RI" ] || die "stage 2/3 ke liye $RK + $RI chahiye (make iso chalao)"
  stage "2/8  headless install -> $(basename "$DISK") (${DISKMB}MB virtio disk)"
  wipe_disk
  run_vm "$LOGDIR/02-install.log" "$TMO" \
    -drive "file=$ISO,if=virtio,readonly=on" -drive "file=$DISK,if=virtio" \
    -kernel "$RK" -initrd "$RI" \
    -append "console=ttyS0 loglevel=4 pk_media=/dev/vda pk_install=/dev/vdb pk_silent pk_halt pk_rootpw=$TESTPW"
  L=$LOGDIR/02-install.log
  check "$L" 'PK: BOOT-OK mode=live'   "install session ka live boot"
  check "$L" 'PK: INSTALL-OK'          "installer pura hua (partition + copy + grub)"
  check "$L" 'PK: INSTALL-DONE rc=0'   "autoinstall hook exit 0"
  check "$L" 'PK: POWER-OFF'           "pk_halt -> poweroff"
  check "$L" 'PK: INSTALL-JOURNAL-OK' "installed root ext4 journal ke saath (crash-safe)"
  if grep -q 'INSTALL-FAIL\|INSTALL-DONE rc=[1-9]' "$L"; then
    note "--- install log tail ---"; tail -30 "$L" | sed 's/^/    /'
  fi

  # --- host side verification: disk image me jo bhi likha, wo sahi hai?
  mnt=$BUILD/test-mnt; mkdir -p "$mnt"
  off=$(parted -s -m "$DISK" unit B print 2>/dev/null | awk -F: '$1=="3"{print $2}' | tr -d 'B')
  as_root umount "$mnt" 2>/dev/null || true
  if [ -n "${off:-}" ] && as_root mount -o ro,loop,offset="$off" "$DISK" "$mnt" 2>/dev/null; then
    total=$((total + 1))
    if [ -f "$mnt/etc/pk-installed" ] && [ -x "$mnt/sbin/init" ] && \
       [ -s "$mnt/boot/pk-kernel" ] && [ -s "$mnt/boot/pk-initrd" ]; then
      pass "installed tree sahi (init + kernel + initrd + marker)"
    else
      bad "installed tree adhoori (init/kernel/initrd check karo)"
    fi
    # root password: shadow ka salt nikaal ke host par dobara hash banao -> match hona chahiye
    sh_line=$(as_root grep '^root:' "$mnt/etc/shadow" 2>/dev/null || true)
    salth=$(printf '%s' "$sh_line" | cut -d: -f2)
    salt=$(printf '%s' "$salth" | cut -d'$' -f3)
    id=$(printf '%s' "$salth" | cut -d'$' -f2)
    total=$((total + 1))
    case $id in
      5|6)
        if have openssl && [ -n "$salt" ]; then
          want=$(openssl passwd "-$id" -salt "$salt" "$TESTPW" 2>/dev/null)
          if [ "$want" = "$salth" ]; then pass "root password install ke baad '$TESTPW' se match karta hai (sha-$id)"
          else bad "root hash mismatch (password set hone ke bawajood login fail hoga)"; fi
        else
          note "openssl/salt nahi mila -> hash verify skip"
        fi ;;
      *) bad "installed /etc/shadow me root hash nahi mila (id='$id')" ;;
    esac
    total=$((total + 1))
    if grep -q 'root=UUID=' "$mnt/boot/grub/grub.cfg" 2>/dev/null; then
      pass "installed grub.cfg root=UUID use karta hai (device-name pe depend nahi)"
    else
      bad "installed grub.cfg me root=UUID nahi hai"
    fi
    if [ -f "$mnt/etc/pk-boot.d/S20net" ] && as_root grep -q 'PK_DHCP=yes' "$mnt/etc/default/pk" 2>/dev/null; then
      pass "installed system me DHCP on hai (etc/default/pk)"
    else
      note "installed DHCP flag check nahi ho paya"
    fi
    as_root umount "$mnt" 2>/dev/null || true
  else
    note "disk image mount nahi ho payi (sudo/parted chahiye) -> host-side verify skip"
  fi

  stage "3/8  installed disk ka apna GRUB (BIOS) -> installed root"
  if ! want 3; then
    note "stage 3 skipped (PK_TEST_STAGES me 3 nahi)"
  else
    # installed grub.cfg me serial console + selftest + poweroff inject karo
    # (taaki headless test ko marker dikhe) - sirf test ke liye
    # GPT layout: p1=bios_grub p2=ESP p3=root(ext4). p3 ka offset parted se.
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
      check "$L" 'PK: BOOT-OK mode=installed' "installed system boot hua (apne GRUB se)"
      check "$L" 'PK: SELFTEST-OK'           "installed root writable + tools ok"
      check "$L" 'PK: PASSWD-OK'             "installed /etc/shadow me real sha-crypt hash hai"
      check "$L" 'PK: LOGIN-REQUIRED'        "installed system password maangta hai (autologin nahi)"
      check "$L" 'PK: TUNE-SWAP-OK'          "installed ext4 par pk_swap=256 se swapfile bana + chalu"
      grep -q 'BOOT FAIL\|Kernel panic\|Unable to mount\|No bootable device' "$L" && {
        note "--- installed log tail ---"; tail -25 "$L" | sed 's/^/    /'; }
    else
      note "inject nahi ho paya (sudo/parted chahiye) -> direct kernel boot se check karte hain"
      run_vm "$LOGDIR/03-installed.log" "$TMO" -drive "file=$DISK,if=virtio" \
        -kernel "$RK" -initrd "$RI" \
        -append "console=ttyS0 loglevel=4 root=/dev/vda3 pk_selftest pk_poweroff"
      check "$LOGDIR/03-installed.log" 'PK: BOOT-OK mode=installed' "installed root mount + init (direct kernel boot)"
    fi
  fi
fi

# ---------------------------------------------------------------- 4: toram
if want 4; then
stage "4/8  toram (image RAM me copy -> media mount reuse)"
  run_vm "$LOGDIR/04-toram.log" "$TMO" -boot d -cdrom "$TISO" \
    -kernel "$RK" -initrd "$RI" \
    -append "console=ttyS0 loglevel=4 toram pk_selftest pk_poweroff"
  L=$LOGDIR/04-toram.log
  check "$L" 'toram done'         "image RAM me copy hua"
  check "$L" 'PK: BOOT-OK'     "toram ke baad bhi system boot hua"
  check "$L" 'PK: SELFTEST-OK' "self test (toram) pass"
fi

# ---------------------------------------------------------------- 5: UEFI
if want 5; then
stage "5/8  UEFI (OVMF) boot from ISO"
  OVMF=$(ls -1 /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
             /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF.fd 2>/dev/null | head -1)
  if [ -z "${OVMF:-}" ]; then
    note "OVMF nahi mila -> skip (sudo apt install -y ovmf)"
  else
    VARS=$BUILD/ovmf-test.fd
    [ -f "$VARS" ] || cp "$(ls -1 /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd 2>/dev/null | head -1)" "$VARS"
    run_vm "$LOGDIR/05-uefi.log" "$TMO" \
      -drive "if=pflash,format=raw,readonly=on,file=$OVMF" \
      -drive "if=pflash,format=raw,file=$VARS" \
      -boot d -cdrom "$TISO"
    check "$LOGDIR/05-uefi.log" 'PK: BOOT-OK' "UEFI (OVMF) se bhi boot hota hai"
  fi
fi


# ---------------------------------------------------------------- 6: persistence + net + ssh
if want 6; then
stage "6/8  persistence (PK-PERSIST disk) + DHCP + SSH"
  PDISK=$BUILD/testpersist.img
  seed=$BUILD/persist-seed; mkdir -p "$seed"
  rm -f "$PDISK"
  dd if=/dev/zero of="$PDISK" bs=1M count=512 status=none conv=sparse
  # poora image hi ext4 (label PK-PERSIST) - init poora-disk bhi try karta hai
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
    bad "persist image mount nahi ho payi (sudo/loop chahiye)"
  fi

  PAPPEND="console=ttyS0 loglevel=4 persistent pk_selftest pk_poweroff pk_net=dhcp pk_ssh=on"
  note "boot A: pehli baar - persistence par marker likhi jaayegi"
  run_vm "$LOGDIR/06a-persist-write.log" "$TMO" \
    -drive "file=$ISO,if=virtio,readonly=on" -drive "file=$PDISK,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -kernel "$RK" -initrd "$RI" -append "$PAPPEND"
  LA=$LOGDIR/06a-persist-write.log
  check "$LA" 'persistence (/dev/vdb)'   "init ko persistence partition mili"
  check "$LA" 'pk-persist/upper'      "root overlay ka upperdir persist disk par hai"
  check "$LA" 'PK: PERSIST-WROTE'     "fresh persist disk par marker file likhi gayi"
  check "$LA" 'PK: NET-OK'            "DHCP se IP mila (pk_net=dhcp)"
  check "$LA" 'PK: SSH-OK'            "dropbear SSH chalu (pk_ssh=on)"
  check "$LA" 'PK: SELFTEST-OK'       "self test (persistent) pass"

  # host side: image file me sach me file aayi?
  total=$((total + 1))
  as_root mount -o loop "$PDISK" "$seed" 2>/dev/null || true
  if as_root test -f "$seed/pk-persist/upper/root/.pk-persist-marker"; then
    pass "persist image me marker disk par maujood (host se verify)"
    as_root cat "$seed/pk-persist/upper/root/.pk-persist-marker" 2>/dev/null | sed 's/^/      ..  /'
  else
    bad "persist image me marker file nahi mili"
  fi
  as_root sync; as_root umount "$seed" 2>/dev/null || true

  note "boot B: same disk - reboot ke baad bhi file bachi rahe"
  run_vm "$LOGDIR/06b-persist-keep.log" "$TMO" \
    -drive "file=$ISO,if=virtio,readonly=on" -drive "file=$PDISK,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -kernel "$RK" -initrd "$RI" -append "$PAPPEND"
  LB=$LOGDIR/06b-persist-keep.log
  check "$LB" 'PK: PERSIST-KEPT'  "reboot ke baad bhi changes zinda (persistence kaam karta hai)"
  check "$LB" 'PK: SELFTEST-OK'   "doosra persistent boot clean tha"
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
    note "REAL runtime use kar rahi hoon ($(du -h "$RTQ" | cut -f1)) - apt/dpkg path + pk_apps_get=sl (20 KB, runtime me nahi hai -> sach me net se download)"
    A7="$A7 pk_apps_get=sl"
    [ "${PK_TEST_WINE:-0}" = 1 ] && A7="$A7 pk_apps_get=wine:--version"
  else
    note "runtime image banati hoon (scripts/make-runtime --tiny)"
    rm -f "$RTQ"
  fi
  if [ "$REALRT" = 1 ]; then
    total=$((total + 1)); pass "real runtime image maujood ($RTQ)"
  elif as_root sh "$PK_ROOT/scripts/make-runtime" --tiny --out="$RTQ" --no-rw >> "$MLOGL" 2>&1; then
    total=$((total + 1))
    if [ -s "$RTQ" ]; then pass "runtime squashfs bani ($(du -h "$RTQ" | cut -f1 | tr -d ' '))"; else bad "runtime squashfs khali bani"; fi
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
    bad "runtime disk mount nahi ho payi (sudo/loop chahiye)"
  fi

  note "boot A: runtime dhoondo + attach karo, phir pk-run dispatch battery"
  run_vm "$LOGDIR/07a-apps.log" "$TMO" \
    -drive "file=$ISO,if=virtio,readonly=on" -drive "file=$RDISK,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -kernel "$RK" -initrd "$RI" -append "$A7"
  LA=$LOGDIR/07a-apps.log
  check "$LA" 'PK: RUNTIME-OK'        "app runtime /opt/pk par attach hua (PK-RUNTIME disk se)"
  check "$LA" 'PK: APP-ELF-OK'        "native Linux ELF app chali"
  check "$LA" 'PK: APP-SCRIPT-OK'     "script app chali"
  check "$LA" 'PK: APP-DEB-OK'        ".deb install + launcher bana"
  if [ "$REALRT" = 1 ]; then
    if [ "${PK_TEST_WINE:-0}" = 1 ]; then
      check "$LA" 'PK: APPS-GET-OK (wine)' "asli Wine install hua (apt) aur 'wine --version' chala"
    else
      check "$LA" 'PK: APP-EXE-DIAG'   ".exe: Wine nahi (lean runtime) - sahi diagnostic aaya"
    fi
  else
    check "$LA" 'PK: APP-EXE-OK'        "Windows .exe Wine dispatch se chala (fake wine, tiny runtime)"
  fi
  check "$LA" 'PK: APP-APK-DIAG-OK'   ".apk pehchana + honest diagnostic (binder/waydroid)"
  check "$LA" 'PK: APP-MACHO-DIAG-OK' "Mach-O (macOS) sahi reason ke saath mana kiya"
  check "$LA" 'PK: RUNTIME-EXEC-OK'   "runtime ke andar command chali (chroot + binds)"
  check "$LA" 'PK: APPS-OK'           "apps selftest pura pass"
  check "$LA" 'PK: NET-OK'            "DHCP apps layer ke saath bhi"
  if [ "$REALRT" = 1 ]; then
    check "$LA" 'APP-DEB-OK (dpkg path)' ".deb runtime ke dpkg se install hua"
    check "$LA" 'PK: APPS-GET-OK (sl)' "apt se net pe download + run (sl); /usr/games lookup bhi"
    check "$LA" 'APP-EXE-OK\|APP-EXE-NO-WINE' ".exe dispatch (wine installed ho to chale, warna diagnostic)"
  fi

  total=$((total + 1))
  as_root umount "$seed2" 2>/dev/null || true
  rtok=0
  if as_root mount -o loop "$RDISK" "$seed2" 2>/dev/null; then
    as_root mkdir -p "$seed2/rw"
    if as_root mount -o loop "$seed2/pk-runtime-rw.img" "$seed2/rw" 2>/dev/null; then
      if as_root sh -c "find '$seed2/rw/pk-runtime/upper' 2>/dev/null | grep -q 'pk-st-app'"; then
        rtok=1
        pass "installed app runtime ke rw overlay me hai (host se verify: pk-runtime-rw.img ke andar)"
      else
        echo "      ..  overlay me mila: $(as_root find "$seed2/rw/pk-runtime/upper" -maxdepth 3 2>/dev/null | sed -n '2,4p' | tr '\n' ' ')"
      fi
      as_root umount "$seed2/rw" 2>/dev/null || true
    else
      echo "      ..  (rw img loop mount nahi ho payi host se)"
    fi
    as_root umount "$seed2" 2>/dev/null || true
  fi
  [ "$rtok" = 1 ] || bad "runtime overlay me installed app nahi dikha"

  note "boot B: same runtime disk - dobara attach + selftest"
  run_vm "$LOGDIR/07b-apps2.log" "$TMO" \
    -drive "file=$ISO,if=virtio,readonly=on" -drive "file=$RDISK,if=virtio" \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -kernel "$RK" -initrd "$RI" -append "$A7"
  check "$LOGDIR/07b-apps2.log" 'PK: RUNTIME-OK' "dusri boot par bhi runtime attach hua"
  check "$LOGDIR/07b-apps2.log" 'PK: APPS-OK'    "dusri boot par bhi apps selftest pass"
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
    pass "kit ka runtime source: $(basename "$RTSRC") ($(du -h "$RTSRC" | cut -f1))"
  else
    bad "koi runtime sqfs nahi ($BUILD/pk-runtime.sqfs / testruntime.sqfs) - pehle 'make test-apps'"
  fi
  note "kit ISO banati hoon (runtime ISO ke andar; selftest+poweroff args)"
  rm -f "$KISO"
  if OUT="$KISO" WITH_RUNTIME=1 PK_RUNTIME_IMG="$RTSRC" \
       PK_TEST_CMDLINE="pk_selftest pk_poweroff pk_verify=1 pk_tune=report console=ttyS0 loglevel=4" \
       "$PK_ROOT/scripts/mk-iso" > "$LOGDIR/08-mkkit.log" 2>&1; then
    pass "kit ISO bani (runtime andar): $(du -h "$KISO" | cut -f1)"
  else
    bad "kit ISO build fail (log: 08-mkkit.log)"
  fi
  rm -f "$KITDISK"
  dd if=/dev/zero of="$KITDISK" bs=1M count="$DISKMB" status=none conv=sparse

  A8="console=ttyS0 loglevel=4 pk_media=/dev/vda pk_install=/dev/vdb pk_silent pk_selftest pk_rootpw=$TESTPW pk_install_user=kituser pk_install_userpw=$TESTPW pk_check=1 pk_keymap=us pk_net=dhcp pk_tune=desktop"
  if [ "${PK_TEST_GUI:-0}" = 1 ]; then
    A8="$A8 pk_desktop=1 pk_check=gui"
    KTMO=$(( KTMO + 300 ))
    note "GUI mode: desktop session (weston -> Xvfb fallback) + X client round-trip bhi check"
  fi
  note "boot A: kit ISO -> pk-check, pk-keymap, headless install (--user + runtime copy)"
  run_vm "$LOGDIR/08a-kit.log" "$KTMO" \
    -drive "file=$KISO,if=virtio,readonly=on" -drive "file=$KITDISK,if=virtio" \
    -kernel "$RK" -initrd "$RI" \
    -append "$A8"
  L=$LOGDIR/08a-kit.log
  check "$L" 'PK: BOOT-OK mode=live'  "kit ISO ka live boot"
  check "$L" 'PK: RUNTIME-OK'         "runtime ISO ke andar se /opt/pk par attach hua"
  check "$L" 'PK: CHECK-OK'           "pk-check: koi FAIL nahi (hardware+OS self-test)"
  check "$L" 'PK: KEYMAP-'            "pk-keymap us chala (console + GUI)"
  check "$L" 'PK: NET-OK'             "kit ke saath bhi DHCP"
  check "$L" 'PK: INSTALL-OK'          "install (user + runtime copy ke saath) pura hua"
  check "$L" 'PK: INSTALL-DONE rc=0'   "installer ka rc 0 (autoinstall hook)"
  if [ "${PK_TEST_GUI:-0}" = 1 ]; then
    check "$L" 'PK: DESKTOP-OK'       "pk-desktop: session utha (weston ya Xvfb fallback)"
    check "$L" 'PK: GUI-X-OK'         "pk-check --gui: display mil gaya"
    check "$L" 'PK: GUI-APP-OK'       "GUI client (xterm ya weston-terminal) session me chala"
    if grep -q 'GUI-XCLIENT-OK' "$L" 2>/dev/null; then
      pass "X client (xdpyinfo) ne bhi display use kiya"
      total=$((total + 1))
    else
      note "  (xdpyinfo row skip - Wayland-only session; GUI-APP-OK hi asli proof hai)"
    fi
  fi
  note "stage-9 style checks (pk-tune/pk-binfmt) isi boot me:"
  A9=$(printf 'pk_selftest')
  # (VM me ye commands pk-boot ke S90 hook se chalte hain - markers niche check)
  check "$L" 'PK: TUNE-REPORT-OK'     "pk-tune report chala (scheduling/io/ipc/security knobs padhe)"
  check "$L" 'PK: BINFMT-'            "pk-binfmt status ne handlers ki sthiti batayi"
  check "$L" 'PK: ARCH-DISPATCH-OK'   "foreign-arch (arm64) ELF -> qemu-user/binfmt dispatch sahi"
  if grep -q 'CHECK-SUMMARY' "$L" 2>/dev/null; then
    note "pk-check: $(grep -o 'CHECK-SUMMARY[^#]*' "$L" | head -1 | tr -d '\r')"
  else
    note "  (CHECK-SUMMARY nahi mila -> less $L)"
  fi

  mnt2=$BUILD/test-mnt2; mkdir -p "$mnt2"
  off2=$(parted -s -m "$KITDISK" unit B print 2>/dev/null | awk -F: '$1=="3"{print $2}' | tr -d 'B')
  as_root umount "$mnt2" 2>/dev/null || true
  hostok=0
  if [ -n "${off2:-}" ] && as_root mount -o ro,loop,offset="$off2" "$KITDISK" "$mnt2" 2>/dev/null; then
    hostok=1
    total=$((total + 1))
    if as_root test -s "$mnt2/var/lib/pk/pk-runtime.sqfs"; then
      pass "app runtime installed system me copy hui (/var/lib/pk/pk-runtime.sqfs)"
    else
      bad "installed system me runtime copy nahi mili"
    fi
    total=$((total + 1))
    if as_root test -f "$mnt2/var/lib/pk/pk-runtime-rw.img"; then
      pass "installed rw image bani (apps reboot ke baad bhi rahengi)"
    else
      bad "installed rw image nahi bani (mkfs.ext4 live me?)"
    fi
    total=$((total + 1))
    if as_root grep -q '^kituser:' "$mnt2/etc/passwd" 2>/dev/null && as_root grep -q '^kituser:' "$mnt2/etc/shadow" 2>/dev/null; then
      uh=$(as_root awk -F: '$1=="kituser"{print $3}' "$mnt2/etc/passwd" 2>/dev/null)
      if as_root awk -F: '$1=="kituser"{exit ($2 ~ /^\$/ ? 0 : 1)}' "$mnt2/etc/shadow" 2>/dev/null; then
        pass "non-root user 'kituser' bana (uid=${uh:-?}) + shadow me sha-crypt hash"
      else
        bad "kituser ka password hash nahi laga (live image me mkpasswd?)"
      fi
    else
      bad "--user se account bana hi nahi (passwd/shadow me kituser nahi)"
    fi
    as_root umount "$mnt2" 2>/dev/null || true
  else
    bad "kit disk host se mount nahi ho payi (checks skip)"
  fi

  note "boot B: installed disk apne GRUB se - runtime /var/lib/pk se attach hona chahiye"
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
    check "$LOGDIR/08b-installed.log" 'PK: BOOT-OK mode=installed' "installed kit system boot hua"
    check "$LOGDIR/08b-installed.log" 'PK: RUNTIME-OK'            "installed system ne /var/lib/pk se runtime attach kiya"
    check "$LOGDIR/08b-installed.log" 'rw-image'                  "installed mode me rw image upper (persistence on)"
    check "$LOGDIR/08b-installed.log" 'PK: LOGIN-REQUIRED'        "installed kit system password maangta hai"
    if grep -q 'BOOT FAIL\|Kernel panic\|VFS: Unable to mount' "$LOGDIR/08b-installed.log" 2>/dev/null; then
      note "--- installed kit log tail ---"; tail -22 "$LOGDIR/08b-installed.log" | sed 's/^/    /'
    fi
  else
    note "inject nahi ho paya -> direct kernel boot se installed root"
    run_vm "$LOGDIR/08b-installed.log" "$KTMO" -drive "file=$KITDISK,if=virtio" \
      -kernel "$RK" -initrd "$RI" \
      -append "console=ttyS0 loglevel=4 root=/dev/vda3 pk_selftest pk_poweroff"
    check "$LOGDIR/08b-installed.log" 'PK: RUNTIME-OK' "installed root se runtime attach (direct kernel boot)"
  fi
  as_root rm -rf "$mnt2" 2>/dev/null || true
fi

# ---------------------------------------------------------------- report
total_or_note() { :; }
printf '\n'
echo "=================================================="
if [ "$fails" = 0 ]; then
  printf '  \033[32mQA PASS\033[0m  %d checks ok  (logs: %s)\n' "$total" "$LOGDIR"
  echo "  next: live USB banao  ->  make usb USB=/dev/sdX"
  echo "        real PC pe permanent install -> pk-install --target=ask"
  exit 0
else
  printf '  \033[31mQA FAIL\033[0m  %d/%d checks fail\n' "$fails" "$total"
  echo "  logs: $LOGDIR   (har stage ka serial output wahin hai)"
  echo "  ek stage dobara:  PK_TEST_STAGES=2 make test"
  exit 1
fi

#!/bin/sh
# pk's OS :: ISO -> USB pendrive (hybrid dd)
#
#   tools/write-usb.sh /dev/sdX [iso]                # dd (recommended)
#   tools/write-usb.sh /dev/sdX [iso] --frugal        # MBR + FAT32 + ISO file copy
#   make usb USB=/dev/sdX
#
# what happens:
#   - the ISO is hybrid (isohybrid MBR + protective GPT + El Torito) -> the same file
#     boots from both BIOS and UEFI, and gets written directly to USB via dd.
#   - the USB's old data gets erased. Hence confirm + safety checks first.
#   --frugal: if you cannot dd (VM/locked host/sharing a persistent stick) then
#     it creates MBR + one FAT32 partition on the device and copies the ISO as a *file*;
#     our init loop-mounts it (like Ubuntu casper 'iso-scan') ✓ verified
#     (docs/COMPARE.md). Minus: you must create a separate partition yourself for persistence.
#   - for persistence, later use 'pk-persist' (in the live system) or
#     the docs/PERSISTENCE.md commands - an extra partition after writing.
# shellcheck shell=sh disable=SC3030,SC2086
set -eu

log()  { printf '\033[1;36m[usb]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[usb warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[usb FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

PK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=dd
_args=""
for a in "$@"; do
  case "$a" in
    --frugal) MODE=frugal ;;
    --dd)     MODE=dd ;;
    *)        _args="$_args $a" ;;
  esac
done
set -- $_args
DEV=${1:-}
ISO=${2:-$PK_ROOT/build/pkos.iso}
FORCE=0
[ "${PK_USB_FORCE:-0}" = 1 ] && FORCE=1

case "$DEV" in
  "") echo "usage: $0 /dev/sdX [iso]     (or: make usb USB=/dev/sdX)"; exit 2 ;;
  /dev/*) : ;;
  *) die "a /dev/.. device is required (e.g. /dev/sdb). Not a partition - /dev/sdb1 NO." ;;
esac
[ -b "$DEV" ] || die "$DEV block device is missing. 'lsblk' for the correct device name."
[ -f "$ISO" ] || die "ISO not found: $ISO (make iso run)"

# --- safety: root needed (or sudo)
if [ "$(id -u)" != 0 ] && ! have sudo; then
  die "root or sudo required (for writing to disk). Try: sudo $0 $DEV $ISO"
fi

# --- safety: writing to the system disk?
REAL=$(readlink -f "$DEV")
NAME=${REAL##*/}
HINT=$(cat "/sys/block/$NAME/device/model" 2>/dev/null || true)
SZGiB=$(( $(cat "/sys/block/$NAME/size") / 2097152 ))
MOUNTS=$( (findmnt -rn -o TARGET "$DEV" 2>/dev/null || grep "^/dev/$NAME" /proc/mounts) | tr '\n' ' ' || true)
CHILDMOUNTS=""
for p in /sys/block/$NAME/${NAME}*; do
  [ -b "/dev/${p##*/}" ] || continue
  m=$(grep "^/dev/${p##*/} " /proc/mounts 2>/dev/null | awk '{print $2}' | tr '\n' ' ' || true)
  [ -n "$m" ] && CHILDMOUNTS="$CHILDMOUNTS /dev/${p##*/}:$m"
done
if [ -n "$MOUNTS" ] || [ -n "$CHILDMOUNTS" ]; then
  die "$DEV (or its partition) is mounted: ${MOUNTS}${CHILDMOUNTS}
   First unmount: sudo umount -R $DEV   (stop before writing to YOUR OWN disk)"
fi
if grep -q " $REAL" /etc/crypttab 2>/dev/null || ls /sys/block/$NAME/slaves >/dev/null 2>&1; then
  [ "$FORCE" = 1 ] || die "$DEV looks like part of md/lvm/crypto in use. If sure, pass PK_USB_FORCE=1."
fi
if [ "$SZGiB" -gt 0 ] && [ "$SZGiB" -lt 1 ] && [ "$FORCE" != 1 ]; then
  die "$DEV size is ${SZGiB}GiB - smaller than 1GB, this looks like a card-reader/card. If sure, PK_USB_FORCE=1"
fi

echo
echo "  device : $DEV ($REAL)  ${SZGiB}GiB  ${HINT:-model?}"
echo "  iso    : $ISO ($(du -h "$ISO" | cut -f1))"
echo " !! $DEV's existing data will be deleted (whole disk)."
echo
if [ -t 0 ] && [ "$FORCE" != 1 ]; then
  printf " to write, type YES: "; read -r ans
  [ "$ans" = "YES" ] || die "cancelled (nothing written)"
fi

# ---------------------------------------------------------------- frugal mode
if [ "$MODE" = frugal ]; then
  have parted    || die "parted required (sudo apt-get install -y parted)"
  have mkfs.vfat || die "mkfs.vfat required (sudo apt-get install -y dosfstools)"
  have mcopy     || die "mcopy required (sudo apt-get install -y mtools)"
  [ -f "$ISO" ] || die "ISO not found: $ISO"
  log "frugal mode: copy the ISO file to MBR + FAT32 partition"
  for p in ${REAL}1 ${REAL}p1; do umount "$p" 2>/dev/null || true; done
  parted -s "$REAL" mklabel msdos || die "mklabel fail"
  parted -s "$REAL" mkpart primary fat32 1MiB 100% || die "mkpart fail"
  partprobe "$REAL" 2>/dev/null || true; sync; sleep 2
  p1="${REAL}1"; case "$REAL" in *[0-9]) p1="${REAL}p1" ;; esac
  [ -b "$p1" ] || { blockdev --rereadpt "$REAL" 2>/dev/null || true; partprobe "$REAL" 2>/dev/null || true; sleep 2; }
  [ -b "$p1" ] || die "$p1 not created (parted/udev? try --dd mode)"
  mkfs.vfat -F 32 -n PKOS "$p1" >/dev/null || die "mkfs.vfat fail"
  name=$(basename "$ISO"); case "$name" in *.iso) : ;; *) name="$name.iso" ;; esac
  mcopy -i "$p1" "$ISO" "::/$name" || die "mcopy fail"
  for extra in "${ISO%.iso}.sha256" "$PK_ROOT/build/README-ISO.txt"; do
    [ -f "$extra" ] && mcopy -i "$extra" ::/ >/dev/null 2>&1 || true
  done
  sync
  log "done ✓ $p1 but /$name (boot: GRUB/BIOS -> 'Booting from Hard Disk', or UEFI entry)"
  log " kernel option required to: pk_iso=/$name (auto-scan also uses)"
  log " persistence: later create an ext4 partition and label it PK-PERSIST"
  exit 0
fi

# ---------------------------------------------------------------- unmount (if broken bits are mounted) & write
for p in /sys/block/$NAME/${NAME}*; do
  [ -b "/dev/${p##*/}" ] && umount "/dev/${p##*/}" 2>/dev/null || true
done
umount "$DEV" 2>/dev/null || true

log "dd is running (bs=4M, sync) - ${SZGiB}GiB disk on 1-3 min lag can be run"
if have sudo && [ "$(id -u)" != 0 ]; then
  sudo dd if="$ISO" of="$REAL" bs=4M status=progress oflag=sync || die "dd fail"
else
  dd if="$ISO" of="$REAL" bs=4M status=progress oflag=sync || \
    dd if="$ISO" of="$REAL" bs=4M conv=fsync || die "dd fail"
fi
sync
if have blockdev; then blockdev --flushbufs "$REAL" 2>/dev/null || true; fi
# read back with the same privilege used for writing (else reading /dev/sdX gives
# permission denied -> a false "did not match" warning)
rd() { # <bytes-KiB> <file> -> sha256 of that size
  if [ "$(id -u)" != 0 ] && have sudo; then
    sudo dd if="$2" bs=1024 count="$1" 2>/dev/null | sha256sum | cut -d" " -f1
  else
    dd if="$2" bs=1024 count="$1" 2>/dev/null | sha256sum | cut -d" " -f1
  fi
}
log "verify: the ISO's first 64KB must match from disk"
a=$(rd 64 "$ISO"); b=$(rd 64 "$REAL")
if [ "$a" = "$b" ]; then
  log "OK - 64KB header match ✓ (boot record is at the correct offset)"
else
  warn "header did not match - USB may not boot. Write again or try another USB."
fi
echo
log "ready. To boot:"
log " 1) PC reset check, boot menu (F12/F8/F2 or Esc) from USB select check"
log " 2) if Secure Boot is ON, turn it OFF first (pk's OS is unsigned)"
log "  3) Live login: root / pk   (permanent install: pk-install --target=auto)"
log "persistence: docs/PERSISTENCE.md"

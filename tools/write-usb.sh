#!/bin/sh
# pk's OS :: ISO -> USB pendrive (hybrid dd)
#
#   tools/write-usb.sh /dev/sdX [iso]                # dd (recommended)
#   tools/write-usb.sh /dev/sdX [iso] --frugal        # MBR + FAT32 + ISO file copy
#   make usb USB=/dev/sdX
#
# kya hota hai:
#   - ISO hybrid hai (isohybrid MBR + protective GPT + El Torito) -> same file
#     BIOS aur UEFI dono se boot karti hai, aur dd se seedha USB pe likhi jaati hai.
#   - USB ka purana data MIT jaata hai. Isliye pehle confirm + safety checks.
#   --frugal: dd nahi kar sakte (VM/locked host/persistent stick share karna ho) to
#     device par MBR + ek FAT32 partition bana ke ISO *file* ke roop me copy karta hai;
#     hamara init use loop-mount kar leta hai (Ubuntu casper 'iso-scan' jaisa) ✓ verified
#     (docs/COMPARE.md). Minus: persistence ke liye alag partition khud banana padega.
#   - persistence chahiye to baad me 'pk-persist' (live system me) ya
#     docs/PERSISTENCE.md wale commands use karo - likhne ke baad extra partition.
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
  "") echo "usage: $0 /dev/sdX [iso]     (ya: make usb USB=/dev/sdX)"; exit 2 ;;
  /dev/*) : ;;
  *) die "device /dev/.. hona required (jaise /dev/sdb). Partition not - /dev/sdb1 NAHI." ;;
esac
[ -b "$DEV" ] || die "$DEV block device is missing. 'lsblk' for the correct device name."
[ -f "$ISO" ] || die "ISO not found: $ISO (make iso run)"

# --- safety: root chahiye (ya sudo)
if [ "$(id -u)" != 0 ] && ! have sudo; then
  die "root or sudo required (disk on likhne for). Try: sudo $0 $DEV $ISO"
fi

# --- safety: system disk pe likh rahe ho?
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
  die "$DEV (ya uska partition) mounted hai: ${MOUNTS}${CHILDMOUNTS}
   Pehle unmount karo: sudo umount -R $DEV   (APNI disk pe write karne se pehle ruk jao)"
fi
if grep -q " $REAL" /etc/crypttab 2>/dev/null || ls /sys/block/$NAME/slaves >/dev/null 2>&1; then
  [ "$FORCE" = 1 ] || die "$DEV any md/lvm/crypto hissa looks like it is in use. Sure ho to PK_USB_FORCE=1 pass it."
fi
if [ "$SZGiB" -gt 0 ] && [ "$SZGiB" -lt 1 ] && [ "$FORCE" != 1 ]; then
  die "$DEV ka size ${SZGiB}GiB - 1GB from chhota, ye card-reader/card looks like is. Sure ho to PK_USB_FORCE=1"
fi

echo
echo "  device : $DEV ($REAL)  ${SZGiB}GiB  ${HINT:-model?}"
echo "  iso    : $ISO ($(du -h "$ISO" | cut -f1))"
echo " !! $DEV ka maujooda data delete ho jaayega (poora disk)."
echo
if [ -t 0 ] && [ "$FORCE" != 1 ]; then
  printf " likhne for YES type check: "; read -r ans
  [ "$ans" = "YES" ] || die "cancel done (anything not likha)"
fi

# ---------------------------------------------------------------- frugal mode
if [ "$MODE" = frugal ]; then
  have parted    || die "parted required (sudo apt-get install -y parted)"
  have mkfs.vfat || die "mkfs.vfat required (sudo apt-get install -y dosfstools)"
  have mcopy     || die "mcopy required (sudo apt-get install -y mtools)"
  [ -f "$ISO" ] || die "ISO not found: $ISO"
  log "frugal mode: MBR + FAT32 partition me ISO file copy"
  for p in ${REAL}1 ${REAL}p1; do umount "$p" 2>/dev/null || true; done
  parted -s "$REAL" mklabel msdos || die "mklabel fail"
  parted -s "$REAL" mkpart primary fat32 1MiB 100% || die "mkpart fail"
  partprobe "$REAL" 2>/dev/null || true; sync; sleep 2
  p1="${REAL}1"; case "$REAL" in *[0-9]) p1="${REAL}p1" ;; esac
  [ -b "$p1" ] || { blockdev --rereadpt "$REAL" 2>/dev/null || true; partprobe "$REAL" 2>/dev/null || true; sleep 2; }
  [ -b "$p1" ] || die "$p1 not bana (parted/udev? --dd mode use check)"
  mkfs.vfat -F 32 -n PKOS "$p1" >/dev/null || die "mkfs.vfat fail"
  name=$(basename "$ISO"); case "$name" in *.iso) : ;; *) name="$name.iso" ;; esac
  mcopy -i "$p1" "$ISO" "::/$name" || die "mcopy fail"
  for extra in "${ISO%.iso}.sha256" "$PK_ROOT/build/README-ISO.txt"; do
    [ -f "$extra" ] && mcopy -i "$extra" ::/ >/dev/null 2>&1 || true
  done
  sync
  log "done ✓ $p1 but /$name (boot: GRUB/BIOS -> 'Booting from Hard Disk', or UEFI entry)"
  log " kernel option required to: pk_iso=/$name (auto-scan also uses)"
  log " persistence: later ek ext4 partition bana ke label PK-PERSIST pass it"
  exit 0
fi

# ---------------------------------------------------------------- unmount (agar kuch toot-futa mounted ho) & write
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
# read-back bhi usi privilege se karo jo write me use hui (warna /dev/sdX padhne par
# permission denied -> "match nahi hua" ka jhootha warning)
rd() { # <bytes-KiB> <file> -> us size ka sha256
  if [ "$(id -u)" != 0 ] && have sudo; then
    sudo dd if="$2" bs=1024 count="$1" 2>/dev/null | sha256sum | cut -d" " -f1
  else
    dd if="$2" bs=1024 count="$1" 2>/dev/null | sha256sum | cut -d" " -f1
  fi
}
log "verify: ISO ka pehla 64KB disk from match to run required"
a=$(rd 64 "$ISO"); b=$(rd 64 "$REAL")
if [ "$a" = "$b" ]; then
  log "OK - 64KB header match ✓ (boot record is at the correct offset)"
else
  warn "header match not hua - USB boot na kare. Dobara likho or doosra USB try check."
fi
echo
log "tayyar. Boot to run for:"
log " 1) PC reset check, boot menu (F12/F8/F2 or Esc) from USB select check"
log " 2) Secure Boot ON ho to first OFF check (pk's OS signed is missing)"
log "  3) Live login: root / pk   (permanent install: pk-install --target=auto)"
log "persistence: docs/PERSISTENCE.md"

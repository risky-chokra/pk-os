#!/bin/sh
# pk's OS :: is the written image lying on the pendrive/disk? (check from host)
#   tools/verify-usb.sh /dev/sdX                    # mounting the device partitions
#   tools/verify-usb.sh /mnt/point                  # already mounted path
#   tools/verify-usb.sh --iso build/pkos.iso        # check the ISO file itself
#   tools/verify-usb.sh /dev/sdX build/manifest.txt # compare with manifest (rebuild verify)
#
# root is needed to mount devices (not for mount points / --iso).
set -u
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

TARGET=${1:-}
MANIFEST=${2:-}
ISOFILE=''
MOUNTIT=0
case "$TARGET" in
  --iso) ISOFILE=${2:-}; MANIFEST=${3:-} ;;
  /dev/*) MOUNTIT=1 ;;
  "") echo "usage: tools/verify-usb.sh <dev|/mnt/path|--iso file.iso> [manifest.txt]"; exit 1 ;;
esac
[ -n "$TARGET" ] || TARGET=$ISOFILE
have() { command -v "$1" >/dev/null 2>&1; }
have sha256sum || { echo "sha256sum required"; exit 1; }
ok=0; bad=0; skip=0
say()  { printf '%s\n' "$*"; }
line() { # <ok|bad|skip> <name> <detail>
  case "$1" in
    ok)   ok=$((ok + 1));   printf '  [ok  ] %-22s %s\n' "$2" "$3" ;;
    bad)  bad=$((bad + 1)); printf '  [FAIL] %-22s %s\n' "$2" "$3" ;;
    *)    skip=$((skip + 1)); printf '  [skip] %-22s %s\n' "$2" "$3" ;;
  esac
}
want_hash() { # <path-in-image> -> expected sha or empty
  [ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || return 1
  h=$(grep -F " /$1 " "$MANIFEST" 2>/dev/null | head -1 | cut -d' ' -f1)
  [ -n "$h" ] || h=$(grep -F "/$1" "$MANIFEST" 2>/dev/null | head -1 | cut -d' ' -f1)
  [ -n "$h" ] || return 1
  printf '%s\n' "$h"
}
check_file() { # <real path> <name-for-manifest>
  f=$1; name=$2
  [ -f "$f" ] || { line skip "$name" "present not"; return; }
  h=$(sha256sum "$f" | cut -d' ' -f1)
  sz=$(du -h "$f" | cut -f1)
  exp=$(want_hash "$name" || true)
  if [ -n "${exp:-}" ]; then
    if [ "$exp" = "$h" ]; then line ok "$name" "$sz  sha256 $h"
    else line bad "$name" "HASH MISMATCH (mil $h, required $exp)"; fi
  else
    line ok "$name" "$sz  sha256 $h"
  fi
}

TDIR=$(mktemp -d /tmp/pk-verify.XXXXXX)
umount_all() {
  for m in "$TDIR"/*; do [ -d "$m" ] && umount "$m" 2>/dev/null; done
  chmod -R u+rwX "$TDIR" 2>/dev/null; rm -rf "$TDIR"
}
trap umount_all EXIT INT TERM

say "pk's OS verify: $TARGET"
say "----------------------------------------------------------------"

if [ -n "$ISOFILE" ]; then
  [ -f "$ISOFILE" ] || { echo "ISO not found: $ISOFILE"; exit 1; }
  say " (ISO file mode - extracting and checking)"
  have xorriso || { echo "xorriso required (sudo apt-get install -y xorriso)"; exit 1; }
  xorriso -osirrox on -indev "$ISOFILE" -extract / "$TDIR/iso" >/dev/null 2>&1 || { echo "extract fail"; exit 1; }
  check_file "$TDIR/iso/boot/pk-kernel"   "boot/pk-kernel"
  check_file "$TDIR/iso/boot/pk-initrd"   "boot/pk-initrd"
  check_file "$TDIR/iso/live/pk.sqfs"     "live/pk.sqfs"
  check_file "$TDIR/iso/live/pk-runtime.sqfs" "live/pk-runtime.sqfs"
  say "----------------------------------------------------------------"
  printf '  result: ok=%s fail=%s skip=%s\n' "$ok" "$bad" "$skip"
  [ "$bad" = 0 ] || exit 1
  exit 0
fi

# ---------- block device: hybrid MBR + partitions content
if [ "$MOUNTIT" = 1 ]; then
  [ -r "$TARGET" ] || { echo "cannot read device: $TARGET (root? sudo)"; exit 1; }
  mbr=$(dd if="$TARGET" bs=512 count=1 2>/dev/null | od -An -tx1 -j510 -N2 | tr -d ' \n')
  if [ "$mbr" = "55aa" ]; then line ok "mbr/bootsector" "55AA ✓ (dd-written image is bootable)"
  else line bad "mbr/bootsector" "55AA not found (m='$mbr') - image incomplete was written?"; fi
  gpt=$(dd if="$TARGET" bs=512 skip=1 count=1 2>/dev/null | head -c 8 | grep -c "EFI PART")
  if [ "$gpt" = 1 ]; then line ok "protective-gpt" "yes (UEFI boot for)"
  else line skip "protective-gpt" "not found (BIOS boot only?)" ; fi
  if have blkid; then
    say "  partitions:"
    blkid -o list -w /dev/null 2>/dev/null | grep "^$TARGET" | sed 's/^/    /'
  fi
  PARTS=''
  if have lsblk; then
    PARTS=$(lsblk -nro NAME "$TARGET" 2>/dev/null | grep -v "^${TARGET}\$" | tr '\n' ' ')
  fi
  if [ -z "$PARTS" ]; then
    case "$TARGET" in
      *nvme[0-9]n1|*mmcblk[0-9]|*loop[0-9]) sep=p ;;
      *) sep='' ;;
    esac
    base=$TARGET
    case "$base" in *[0-9]) base="${base}p"; sep='' ;; esac
    i=1
    while [ $i -le 8 ]; do
      [ -b "$base$sep$i" ] && PARTS="$PARTS $base$sep$i"
      i=$((i + 1))
    done
  fi
  found=0
  for p in $PARTS; do
    [ -b "$p" ] || continue
    n=$(basename "$p")
    m="$TDIR/$n"; mkdir -p "$m"
    if mount -o ro "$p" "$m" 2>/dev/null; then
      if [ -f "$m/live/pk.sqfs" ] || [ -f "$m/boot/pk-initrd" ] || [ -d "$m/EFI" ]; then
        found=1
        line ok "content @$p" "/live/pk.sqfs$( [ -f "$m/live/pk-runtime.sqfs" ] && echo ' + app runtime' )"
        check_file "$m/live/pk.sqfs" "live/pk.sqfs"
        check_file "$m/boot/pk-kernel" "boot/pk-kernel"
        check_file "$m/boot/pk-initrd" "boot/pk-initrd"
        check_file "$m/live/pk-runtime.sqfs" "live/pk-runtime.sqfs"
      else
        lbl=$(blkid -s LABEL -o value "$p" 2>/dev/null)
        [ -n "${lbl:-}" ] && say " $p: label=$lbl (no pk payload on this partition)"
      fi
      umount "$m" 2>/dev/null
    else
      say " $p: could not mount (vfat/ext4? or raw BIOS partition)"
    fi
  done
  if [ "$found" = 0 ]; then
    line skip "payload" "/live/pk.sqfs not found in any partition"
    say " (did you copy the ISO *inside* a partition? for the pendrive test, dd the whole ISO,"
    say "     or keep the /live/ dir at the partition root: the 'cp -a isomount/. /dev/sdX1/' flow)"
  fi
else
  # mounted directory mode
  [ -d "$TARGET" ] || { echo "path not: $TARGET"; exit 1; }
  root=$TARGET
  [ -f "$root/live/pk.sqfs" ] || { for c in "$root"/*/live/pk.sqfs; do [ -f "$c" ] && root=${c%/live/pk.sqfs}; done; }
  line info "root" "$root"
  check_file "$root/boot/pk-kernel" "boot/pk-kernel"
  check_file "$root/boot/pk-initrd" "boot/pk-initrd"
  check_file "$root/live/pk.sqfs" "live/pk.sqfs"
  check_file "$root/live/pk-runtime.sqfs" "live/pk-runtime.sqfs"
fi

say "----------------------------------------------------------------"
printf '  result: ok=%s fail=%s skip=%s\n' "$ok" "$bad" "$skip"
say ""
say "  now boot from the pendrive and run:   pk-check --save   (report: /run/pk/check.txt)"
[ "$bad" = 0 ] || { say " FAIL: dd again (tools/write-usb.sh) or the manifest does not match "; exit 1; }
exit 0

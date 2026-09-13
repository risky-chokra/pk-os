#!/bin/sh
# pk's OS :: rootfs/overlay wapas laao, agar workspace/git reset me files ud jaayein.
#   usage: tools/restore-from-iso.sh [path/to/pkos.iso]
#
# Kyun: ISO hi is project ka self-contained backup hai -- live image ke andar
# rootfs/overlay ke saare hand-written files (pk-boot, pk-run, pk-check, inittab,
# motd, boot hooks, ...) maujood hain. Generated cheezein (busybox applets, host
# binaries, /lib/modules, etc/udhcpc symlink, pk-build stamps) wapas nahi laate -
# build-rootfs unheein khud banata hai.
set -eu
PK_ROOT=$(cd "$(dirname "$0")/.." && pwd)
ISO=${1:-}
[ -n "$ISO" ] || ISO=$HOME/pkos-1.0.iso
[ -f "$ISO" ] || { echo "[pk] error: ISO not found: $ISO (or to path pass it, or make iso from banalo)"; exit 1; }
for t in xorriso unsquashfs; do
  command -v "$t" >/dev/null 2>&1 || { echo "[pk] error: '$t' required -> sudo apt-get install -y xorriso squashfs-tools"; exit 1; }
done

T=$(mktemp -d /tmp/pk-restore.XXXXXX)
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T" 2>/dev/null; }
trap cleanup EXIT INT TERM
echo "[pk] ISO extract: $ISO"
xorriso -osirrox on -indev "$ISO" -extract / "$T/iso" >/dev/null 2>&1
SQ=$T/iso/live/pk.sqfs
[ -f "$SQ" ] || { echo "[pk] error: ISO me /live/pk.sqfs not found (ye project ka ISO is?)"; exit 1; }
echo "[pk] squashfs unpack..."
unsquashfs -q -d "$T/sq" -f "$SQ" >/dev/null 2>&1
[ -d "$T/sq" ] || { echo "[pk] error: unsquashfs fail"; exit 1; }

OV=$PK_ROOT/rootfs/overlay
n=0
skip() { :; }
cd "$T/sq"
LIST=$(
  for f in $(find . -type f -size -600k | sort); do
    case "$f" in
      ./lib/*|./usr/lib/*|./usr/share/grub/*|./var/*|./proc/*|./sys/*|./dev/*) continue ;;
      ./etc/ssl/*|./etc/udhcpc/*|./etc/mtab|./etc/ld.so*|./etc/pk-build*|./etc/pk-live-base) continue ;;
      ./etc/mke2fs.conf|./etc/blkid.conf|./etc/e2fsck.conf) continue ;;
      ./sbin/grub-mkconfig|./usr/sbin/grub-mkconfig) continue ;;
      ./boot/*|./mods/*|./newroot/*) continue ;;
    esac
    h=$(head -c4 "$f" | od -An -c | tr -d ' \n')
    [ "$h" = '177ELF' ] && continue          # host binaries / busybox -> generated
    printf '%s\n' "${f#./}"
  done
)
for f in $LIST; do
  mkdir -p "$OV/$(dirname "$f")"
  cp -p "$T/sq/$f" "$OV/$f" 2>/dev/null || cp -f "$T/sq/$f" "$OV/$f"
  n=$((n + 1))
done

# init/ (initramfs ka /init + grub template + module list) bhi check karo
for f in init/init init/grub.cfg init/kernel-modules; do
  if [ ! -s "$PK_ROOT/$f" ]; then
    case "$f" in
      init/init) [ -f "$T/sq/init" ] && { cp -p "$T/sq/init" "$PK_ROOT/$f"; n=$((n+1)); echo "[pk warn] $f wapas laya (initrd /init)"; } ;;
      *) echo "[pk warn] $f gayab is - ye repo in hi hona required was (ISO in not hota)" ;;
    esac
  fi
done

for f in "$OV"/sbin/pk-* "$OV"/bin/pk-* "$OV"/etc/pk-boot.d/S*; do
  [ -f "$f" ] && chmod 755 "$f"
done
for f in "$PK_ROOT"/scripts/* "$PK_ROOT"/tools/*; do
  [ -f "$f" ] && chmod 755 "$f"
done

echo "[pk] restored files into rootfs/overlay : $n"
bad=0
for f in $(find "$OV" -type f \( -name 'pk-*' -o -name 'S[0-9]*' -o -name 'default.script' \) 2>/dev/null); do
  sh -n "$f" 2>/dev/null || { echo "[pk] SYNTAX FAIL: $f"; bad=1; }
done
if [ ! -d "$PK_ROOT/.git" ]; then
  echo "[pk warn] .git not found - history reset in gayab. Naya repo: git init -b main && git add -A && git commit -m 'restore'"
  echo "[pk warn] ...ya better: git clone https://github.com/risky-chokra/pkos.git (ya release ka pkos-1.0.bundle)"
elif ! git -C "$PK_ROOT" remote get-url origin >/dev/null 2>&1; then
  # snapshot me .git/config persist nahi hota -> remote/identity udd jaate hain
  echo "[pk warn] .git/config me 'origin' is missing (config snapshots in persist not hota). Restore:"
  echo "    git -C $PK_ROOT remote add origin https://github.com/risky-chokra/pkos.git"
  echo "    git -C $PK_ROOT config --local user.name  "<naam>""
  echo "    git -C $PK_ROOT config --local user.email "<email>""
fi
[ "$bad" = 0 ] && echo "[pk] sh -n clean ✓  ab: make doctor && make iso"
exit $bad

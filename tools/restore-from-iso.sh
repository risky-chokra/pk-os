#!/bin/sh
# pk's OS :: bring rootfs/overlay back if files fly off in a workspace/git reset.
#   usage: tools/restore-from-iso.sh [path/to/pkos.iso]
#
# Why: the ISO itself is this project's self-contained backup -- inside the live image
# all hand-written files of rootfs/overlay (pk-boot, pk-run, pk-check, inittab,
# motd, boot hooks, ...) are present. Generated stuff (busybox applets, host
# binaries, /lib/modules, etc/udhcpc symlink, pk-build stamps) are not brought back -
# build-rootfs creates them itself.
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
[ -f "$SQ" ] || { echo "[pk] error: /live/pk.sqfs not found in ISO (is this the project ISO?)"; exit 1; }
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

# also check init/ (initramfs /init + grub template + module list)
for f in init/init init/grub.cfg init/kernel-modules; do
  if [ ! -s "$PK_ROOT/$f" ]; then
    case "$f" in
      init/init) [ -f "$T/sq/init" ] && { cp -p "$T/sq/init" "$PK_ROOT/$f"; n=$((n+1)); echo "[pk warn] $f brought back (initrd /init)"; } ;;
      *) echo "[pk warn] $f is missing - it must be in this repo (never in the ISO)" ;;
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
  echo "[pk warn] .git not found - history lost in reset. New repo: git init -b main && git add -A && git commit -m 'restore'"
  echo "[pk warn] ...or better: git clone https://github.com/risky-chokra/pkos.git (or the release pkos-1.0.bundle)"
elif ! git -C "$PK_ROOT" remote get-url origin >/dev/null 2>&1; then
  # .git/config does not persist in snapshots -> remote/identity fly off
  echo "[pk warn] .git/config me 'origin' is missing (config is not persisted in snapshots). Restore:"
  echo "    git -C $PK_ROOT remote add origin https://github.com/risky-chokra/pkos.git"
  echo "    git -C $PK_ROOT config --local user.name  "<name>""
  echo "    git -C $PK_ROOT config --local user.email "<email>""
fi
[ "$bad" = 0 ] && echo "[pk] sh -n clean ✓  now: make doctor && make iso"
exit $bad

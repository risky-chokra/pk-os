#!/bin/sh
# pk's OS :: ISO ke *andar* ke payload files ka manifest (sha256) banao.
#   usage: scripts/manifest.sh [build/pkos.iso] [build/manifest.txt]
#
# Kyun: ISO ka container (xorriso/grub-mkrescue) build timestamp embed karta hai,
# isliye do builds ke ISO bytes same nahi hote. Payload files ke hashes same hote
# hain (SOURCE_DATE_EPOCH ke saath to bilkul) -> "mere build me bhi wahi code hai"
# ye prove karne ka clean tareeka. Real PC / USB verify: tools/verify-usb.sh
set -eu
PK_ROOT=$(cd "$(dirname "$0")/.." && pwd); export PK_ROOT
# shellcheck disable=SC1091
. "$PK_ROOT/scripts/pk.sh"

ISO=${1:-$BUILD/pkos.iso}
OUT=${2:-$BUILD/manifest.txt}
[ -f "$ISO" ] || die "ISO not found: $ISO (first make iso)"
have sha256sum || die "sha256sum required (coreutils)"
have xorriso || die "xorriso required -> sudo apt-get install -y xorriso"

T=$(mktemp -d /tmp/pk-manifest.XXXXXX)
cleanup() { chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT INT TERM
log "ISO extract: $ISO"
xorriso -osirrox on -indev "$ISO" -extract / "$T/iso" >/dev/null 2>&1 || die "extract fail"
SQ=$T/iso/live/pk.sqfs
[ -f "$SQ" ] || die "ISO me /live/pk.sqfs not found - ye pk's OS ka ISO not looks like"

{
  printf '# pk'"'"'s OS manifest\n'
  printf '# generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# source repo commit: %s\n' "$( (cd "$PK_ROOT" && git rev-parse HEAD 2>/dev/null) || echo '(no git)')"
  printf '# SOURCE_DATE_EPOCH: %s\n' "${SOURCE_DATE_EPOCH:-(unset)}"
  printf '\n# ISO container (timestamp embed uses -> pass it builds in differ karega)\n'
  printf '%s  ISO\n' "$(sha256sum "$ISO" | cut -d' ' -f1)"
  printf '\n# payload files (ye stable hone required)\n'
  for f in boot/pk-kernel boot/pk-initrd live/pk.sqfs live/pk-runtime.sqfs; do
    [ -f "$T/iso/$f" ] || continue
    printf '%s  /%s (%s)\n' "$(sha256sum "$T/iso/$f" | cut -d' ' -f1)" "$f" "$(du -h "$T/iso/$f" | cut -f1)"
  done
} > "$OUT"

# OS ke hand-written files (rootfs/overlay) ke hashes - squashfs se selective extract
if have unsquashfs; then
  LIST=$(unsquashfs -l "$SQ" 2>/dev/null | sed -e 's|^squashfs-root/||' \
        | grep -E '^((s?bin|usr/s?bin)/pk-.*|etc/(pk-boot\.d/.*|inittab|motd|os-release|passwd|shadow|group|default/pk|hostname)|usr/share/udhcpc/default\.script|usr/share/doc/pkos/.*)$' | sort || true)
  if [ -n "$LIST" ]; then
    ( cd "$T" && unsquashfs -q -d sq -f "$SQ" $LIST >/dev/null 2>&1 ) || true
    if [ -d "$T/sq" ]; then
      {
        printf '\n# rootfs/overlay files (jo image in gaayi are)\n'
        ( cd "$T/sq" && find . -type f -o -type l | LC_ALL=C sort | while read -r f; do
            p=${f#./}
            if [ -L "$T/sq/$p" ]; then
              printf 'symlink  /%s -> %s\n' "$p" "$(readlink "$T/sq/$p")"
            else
              printf '%s  /%s\n' "$(sha256sum "$T/sq/$p" | cut -d' ' -f1)" "$p"
            fi
          done )
        printf '\n# modules: %s (.ko)  initrd size: %s\n' \
          "$(unsquashfs -l "$SQ" 2>/dev/null | grep -c '\.ko' || echo '?')" \
          "$(du -h "$T/iso/boot/pk-initrd" 2>/dev/null | cut -f1)"
      } >> "$OUT"
    fi
  fi
fi

log "manifest -> $OUT ($(grep -c . "$OUT") lines)"
sed -n '1,6p' "$OUT" | sed 's/^/    /'

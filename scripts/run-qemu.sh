#!/bin/sh
# pk's OS :: QEMU runner (headless or window, BIOS/UEFI, direct kernel too)
#
# usage: run-qemu.sh [opts]
#   -iso FILE     ISO to boot (default build/pkos.iso); -no-iso to skip
#   -hdd FILE     second disk (for target/persistence tests)
#   -uefi         UEFI boot with OVMF pflash
#   -tty          serial on stdio (-nographic), else a window
#   -serial FILE  write serial to a file (headless test)
#   -kernel F -initrd F -append S   direct kernel boot (grub skip)
#   -m MB         RAM (default 2048)
#   -timeout S    outer timeout wrapper
#   -auto         if headless, use direct kernel boot (+ serial console),
#                 so boot shows even without a display; with a display, ISO+GRUB
set -u
PK_ROOT=$(cd "$(dirname "$0")/.." && pwd); export PK_ROOT
# shellcheck disable=SC1091
. "$PK_ROOT/scripts/pk.sh"

QEMU=${QEMU:-qemu-system-x86_64}
have "$QEMU" || die "$QEMU not found -> sudo apt install qemu-system-x86"

ISO=$BUILD/pkos.iso
HDD=""; UEFI=0; TTY=0; MEM=${PK_QEMU_MEM:-2048}; NOACCEL=${PK_QEMU_NOACCEL:-0}; AUTO=0

# if you ask for more than the host's available RAM, lower it (low-RAM / sandbox friendly)
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
if [ "${avail:-0}" -gt 0 ]; then
  cap=$(( avail - 256 ))
  if [ "$cap" -lt 128 ]; then cap=128; fi
  if [ "$MEM" -gt "$cap" ]; then
    echo "[pk warn] MEM $MEM MB > host available (${avail} MB) -> using $cap MB" >&2
    MEM=$cap
  fi
fi
APPEND=""; KER=""; IRD=""; SERIAL=""; NOISO=0; TMO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -iso)      ISO=$2; shift 2 ;;
    -no-iso)   NOISO=1; shift ;;
    -hdd)      HDD=$2; shift 2 ;;
    -uefi)     UEFI=1; shift ;;
    -tty)      TTY=1; shift ;;
    -m)        MEM=$2; shift 2 ;;
    -append)   APPEND=$2; shift 2 ;;
    -kernel)   KER=$2; shift 2 ;;
    -initrd)   IRD=$2; shift 2 ;;
    -serial)   SERIAL=$2; shift 2 ;;
    -timeout)  TMO=$2; shift 2 ;;
    -noaccel)  NOACCEL=1; shift ;;
    -auto)     AUTO=1; shift ;;
    *)         die "unknown arg: $1 (--help-style args are above)" ;;
  esac
done

# headless + -auto -> skip grub, direct kernel/initrd (output comes on serial)
if [ "$AUTO" = 1 ] && [ -z "${DISPLAY:-}" ] && [ -z "$SERIAL" ]; then
  ak=$WORK/iso/boot/pk-kernel; ai=$WORK/iso/boot/pk-initrd
  if [ -f "$ak" ] && [ -f "$ai" ]; then
    KER=$ak; IRD=$ai
    APPEND="${APPEND:-quiet loglevel=3 pk_net= console=tty0 console=ttyS0,115200n8}"
    log "headless: direct kernel boot (GRUB skip). Pure ISO test for: make run-iso" >&2
  fi
fi

if [ "$NOISO" != 1 ]; then
  case "$ISO" in /*) : ;; *) ISO=$PWD/$ISO ;; esac
  [ -f "$ISO" ] || die "ISO not found: $ISO (run: make iso)"
fi

# base args (POSIX: positional params themselves are used as the option list)
set -- -name pkos -machine q35 -cpu max -smp 2 -m "$MEM"
# use KVM if found (10x faster boot on a real PC); else default TCG
if [ "${NOACCEL:-0}" != 1 ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  set -- "$@" -accel kvm
  log "accel: kvm" >&2
fi
set -- "$@" -device virtio-net-pci,netdev=n0 -netdev user,id=n0
if [ -n "$SERIAL" ]; then
  set -- "$@" -display none -serial "file:$SERIAL" -monitor none
elif [ "$TTY" = 1 ] || [ -z "${DISPLAY:-}" ]; then
  # everything in the terminal itself (headless machine / ssh)
  set -- "$@" -nographic -serial mon:stdio
else
  set -- "$@" -display gtk -vga std
fi
[ -n "$HDD" ] && set -- "$@" -drive "file=$HDD,if=virtio"
[ "$NOISO" = 1 ] || set -- "$@" -drive "file=$ISO,if=virtio,readonly=on"
[ -z "$KER" ] || set -- "$@" -kernel "$KER"
[ -z "$IRD" ] || set -- "$@" -initrd "$IRD"
[ -z "$APPEND" ] || set -- "$@" -append "$APPEND"

if [ "$UEFI" = 1 ]; then
  code=""; vars=""
  for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
    [ -r "$c" ] && { code=$c; break; }
  done
  for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [ -r "$v" ] && { vars=$v; break; }
  done
  [ -n "$code" ] && [ -n "$vars" ] || die "OVMF not found -> sudo apt install ovmf"
  nv=$BUILD/ovmf-vars.fd
  [ -f "$nv" ] || cp "$vars" "$nv"
  set -- "$@" -drive "file=$code,if=pflash,format=raw,unit=0,readonly=on" \
              -drive "file=$nv,if=pflash,format=raw,unit=1"
fi

if [ -n "${PK_QEMU_EXTRA:-}" ]; then
  # shellcheck disable=SC2086
  set -- "$@" $PK_QEMU_EXTRA
fi

if [ -n "$TMO" ]; then
  exec timeout -k 5 "$TMO" "$QEMU" "$@"
fi
exec "$QEMU" "$@"

#!/bin/sh
# pk's OS :: take a VM screenshot - a "black screen after GRUB"-style case becomes clear in 20 seconds
#   tools/vm-shot.sh [iso] [out-prefix] [seconds-to-run] [extra qemu args...]
#
# What it does: runs QEMU headless (-display none), on the monitor socket
# sends `screendump`, and creates a PNG - *the same image* the user
# sees in the VM window. You can also pass --kernel/--initrd/-append (in extra args).
#   tools/vm-shot.sh build/pkos.iso /tmp/shot 60
#   tools/vm-shot.sh build/pkos.iso /tmp/safe 60 -append "console=tty0 loglevel=4 nomodeset pk_poweroff"
# deps: qemu-system-x86_64, (convert | pnmcut) - without ImageMagick only PPM/PBM remains.
set -u
ISO=${1:-build/pkos.iso}
OUT=${2:-/tmp/pk-shot}
SECS=${3:-45}
shift 3 2>/dev/null || true
EXTRA="$*"
have() { command -v "$1" >/dev/null 2>&1; }
[ -f "$ISO" ] || { echo "ISO not found: $ISO"; exit 1; }
have qemu-system-x86_64 || { echo "qemu-system-x86_64 required (sudo apt-get install -y qemu-system-x86)"; exit 1; }
MON=$(mktemp -u /tmp/pkshot-mon.XXXXXX)
LOG=$(mktemp /tmp/pkshot-serial.XXXXXX)
SHOTS=""
i=0
D=$(dirname "$OUT"); mkdir -p "$D" 2>/dev/null

shot() { # <label>
  n=$1
  if have socat; then
    printf 'screendump %s-%s.ppm\n' "$OUT" "$n" | socat -t1 - UNIX-CONNECT:"$MON" >/dev/null 2>&1
  elif have python3; then
    python3 - "$MON" "$OUT-$n.ppm" <<'PY' 2>/dev/null || true
import socket,sys
p,out=sys.argv[1],sys.argv[2]
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(3)
try:
    s.connect(p); s.sendall(("screendump %s\n" % out).encode()); s.recv(200)
except Exception: pass
s.close()
PY
  fi
  [ -f "$OUT-$n.ppm" ] && SHOTS="$SHOTS $OUT-$n.ppm"
  if have convert; then
    [ -f "$OUT-$n.ppm" ] && convert "$OUT-$n.ppm" "$OUT-$n.png" 2>/dev/null && SHOTS="$SHOTS $OUT-$n.png"
  fi
  # blank-pixel ratio: this is how a 100% black screen is detected
  if [ -f "$OUT-$n.ppm" ] && have python3; then
    python3 - "$OUT-$n.ppm" <<'PY'
import sys
p=sys.argv[1]
b=open(p,'rb').read()
# P5 ppm: header 'P5 w h 255'
try:
    # P5 header: magic, width, height, maxval - whitespace-separated, line breaks anywhere
    i = 0; toks = []
    while len(toks) < 4 and i < len(b):
        j = b.find(b'\n', i)
        if j < 0: j = len(b)
        toks += b[i:j].split(); i = j + 1
    w, h = int(toks[1]), int(toks[2])
    data = b[i:]
    nonzero=sum(1 for x in data[::7] if x)
    tot=max(1,len(data[::7]))
    print("  shot %s: %dx%d, non-black samples: %.1f%% (%s)" % (p.split('/')[-1], w, h, 100.0*nonzero/tot, "VISIBLE" if nonzero*40>tot else "BLACK/EMPTY"))
except Exception as e:
    print("  (ppm parse skip:", e, ")")
PY
  fi
}

echo "[shot] qemu: $ISO (out=$OUT, ${SECS}s) $EXTRA"
setsid qemu-system-x86_64 -machine q35 -cpu max -smp 2 -m 1536 -cdrom "$ISO" -boot d \
  -vga std -display none -monitor "unix:$MON,server,nowait" \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -serial "file:$LOG" $EXTRA >/dev/null 2>&1 &
QPID=$!
sleep 3
shot grub          # is the GRUB menu showing?
sleep $(( SECS > 20 ? 15 : SECS/2 ))
shot boot          # after boot
i=0
while [ $i -lt 3 ]; do
  sleep 6; shot "late$i"; i=$((i + 1))
done
kill -TERM -$QPID 2>/dev/null || true; sleep 1; kill -KILL -$QPID 2>/dev/null || true
rm -f "$MON" 2>/dev/null
echo "[shot] serial log: $LOG (kernel/console output here)"
echo "[shot] images:$SHOTS"
if [ -s "$LOG" ]; then
  echo "[shot] last console lines:"; tail -5 "$LOG" | sed 's/^/    /'
fi

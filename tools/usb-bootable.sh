#!/bin/sh
# pk's OS :: will a PC actually boot from this stick? diagnose before you reboot.
#
#   tools/usb-bootable.sh /dev/sdX          # a USB stick (read-only checks)
#   tools/usb-bootable.sh build/pkos.iso    # the ISO file itself
#
# It reports exactly what firmware looks for, and says which of the two boot
# paths (UEFI / legacy BIOS) is available. Nothing is written.
set -u
TGT=${1:-}
[ -n "$TGT" ] || { echo "usage: $0 /dev/sdX | image.iso"; exit 2; }
ok=0; warn=0; bad=0; has_uefi=no; has_torito=no; has_part=no
good() { printf '  OK    %s\n' "$*"; ok=$((ok+1)); }
note() { printf '  CHECK %s\n' "$*"; warn=$((warn+1)); }
fail() { printf '  BAD   %s\n' "$*"; bad=$((bad+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

case $TGT in
  /dev/*) [ -b "$TGT" ] || { echo "$TGT is not a block device"; exit 2; }
          sz=$(blockdev --getsize64 "$TGT" 2>/dev/null || echo 0)
          read512() { dd if="$TGT" bs=1 skip="$1" count="$2" iflag=skip_bytes,count_bytes 2>/dev/null | od -An -tx1 | tr -d ' \n'; } ;;
  *)     [ -f "$TGT" ] || { echo "$TGT: no such file"; exit 2; }
          sz=$(wc -c < "$TGT" | tr -d ' ')
          read512() { dd if="$TGT" bs=1 skip="$1" count="$2" iflag=skip_bytes,count_bytes 2>/dev/null | od -An -tx1 | tr -d ' \n'; } ;;
esac
printf 'target: %s (%s bytes)\n' "$TGT" "$sz"

# --- 1. MBR: boot indicator + partition table, and the 0x55AA signature
sig=$(dd if="$TGT" bs=510 skip=1 count=2 2>/dev/null | od -An -tu1 | tr -s ' ')
case "$sig" in *" 85 170"*) good "MBR signature 0x55AA present (DOS/MBR boot sector)" ;;
              *) fail "no MBR signature at offset 0x1FE - no firmware will boot this" ;;
esac
# the first MBR partition entry: 16 bytes at offset 446
rec=$(dd if="$TGT" bs=1 skip=446 count=16 2>/dev/null | od -An -tu1 | tr -s ' ')
p1_boot=$(printf '%s' "$rec" | awk '{print $2}')
p1_type=$(printf '%s' "$rec" | awk '{print $6}')
case "$p1_type" in
  238) has_part=yes; good "protective MBR (type 0xEE) -> GPT layout, what a hybrid ISO produces" ;;
  0)   note "MBR has no partition type (00) - this looks like files copied onto a stick, not a raw image write" ;;
  *)   has_part=yes; good "MBR partition entry present (type $p1_type, boot flag $p1_boot)" ;;
esac
# --- 2. GPT header at LBA 1 (this is what UEFI firmware reads first)
gpt=$(dd if="$TGT" bs=512 skip=1 count=1 2>/dev/null | head -c 8)
if [ "$gpt" = "EFI PART" ]; then
  has_uefi=yes; good "GPT header 'EFI PART' at LBA 1 - UEFI can find the ESP with EFI/BOOT/BOOTX64.EFI"
else
  note "no GPT at LBA 1 - legacy-BIOS-only layout; UEFI firmware often does not list such a stick"
fi
# --- 3. El Torito (CD-ROM emulation) + the squashfs payload
ISO_TREE=""
if have xorriso; then
  ISO_TREE=$(xorriso -dev "$TGT" -find / -maxdepth 2 -type f 2>/dev/null | grep '^/' | head -200 || true)
fi
if [ -n "$ISO_TREE" ]; then
  if printf '%s\n' "$ISO_TREE" | grep -q '^/boot\.catalog$'; then
    has_torito=yes; good "El Torito boot catalogue (/boot.catalog) present"
  else
    note "no /boot.catalog in the ISO9660 part - this is not an El Torito (CD-emulation) image"
  fi
  nb=$(printf '%s\n' "$ISO_TREE" | grep -c '^/boot/')
  if [ "${nb:-0}" -gt 0 ]; then
    good "$nb files under /boot (kernel, initrd, grub.cfg, live payload are where the menu expects them)"
  else
    fail "no /boot tree in the ISO9660 part - the live payload is missing from this image"
  fi
  if printf '%s\n' "$ISO_TREE" | grep -qi '^/efi/boot/bootx64\.efi$'; then
    good "EFI/BOOT/BOOTX64.EFI present in the image (UEFI fallback path)"
  fi
else
  note "xorriso could not list the ISO9660 tree (raw device without an ISO session, or xorriso missing)"
fi
# --- 4. does the filesystem on it still say 'pk's OS'?
if have blkid; then
  case $TGT in /dev/*) lbl=$(blkid -o value -s LABEL "$TGT" 2>/dev/null || true)
                  [ -n "${lbl:-}" ] && printf '  info  filesystem label on the device: %s\n' "$lbl" ;; esac
fi

# A stick is only useful if *some* firmware can find it: GPT(UEFI) or a boot catalogue
# (El Torito) or a real partition type with a bootloader. If none of those, say so loudly.
if [ "$has_uefi" = no ] && [ "$has_torito" = no ] && [ "$has_part" = no ]; then
  fail "no bootable layout at all: no GPT, no El Torito catalogue, no partition type"
fi
echo
if [ "$bad" -gt 0 ]; then
  echo "VERDICT: this stick/ISO is NOT bootable as written ($bad problem(s))."
  echo "  Most common cause: the image was 'extracted' onto the stick instead of written raw."
  echo "  Fix (Windows): Rufus -> when it asks, choose 'DD Image' mode; or use balenaEtcher"
  echo "  (Etcher only ever writes raw). Then in firmware: Secure Boot OFF, Fast Boot OFF."
  exit 1
fi
echo "VERDICT: layout looks bootable - $ok checks ok, $warn to keep in mind."
echo "  If the PC still does not list it: firmware settings (Secure Boot OFF = required,"
echo "  the kernel is unsigned), Fast Boot OFF, 'USB boot' enabled, try a USB 2.0 port,"
echo "  and reach the boot menu with the vendor key (F12/Esc/F8) or from Windows:"
echo "  Settings > Recovery > Advanced start-up > Use a device."
exit 0

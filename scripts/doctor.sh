#!/bin/sh
# pk's OS :: check build-machine dependencies
# shellcheck shell=sh
miss=0
ok()   { printf '  \033[32mOK \033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mMISS\033[0m %s\n' "$*"; miss=$((miss + 1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }
need()  { command -v "$1" >/dev/null 2>&1 && ok "$1 -> $(command -v "$1")" || bad "$1"; }
needf() { [ -e "$1" ] && ok "$1" || bad "$1"; }

echo "== pk's OS build doctor =="
echo "-- ISO banane for --"
need gcc
need make
need mksquashfs
need xorriso
need grub-mkrescue
need cpio
need gzip
need sed
need awk
need tar
echo "-- grub images (ISO + installer) --"
needf /usr/lib/grub/i386-pc/cdboot.img
ok "lnxboot.img optional (grub-mkrescue handles it itself)"
needf /usr/lib/grub/x86_64-efi/modinfo.sh
echo "-- live image content --"
needf /bin/busybox
  bbk=$(for c in /bin/busybox /usr/bin/busybox /bin/busybox.static; do [ -x "$c" ] || continue; ldd "$c" 2>/dev/null | grep -q '=> /' || { echo "$c"; break; }; done)
  [ -n "${bbk:-}" ] && ok "static busybox: $bbk" || bad "busybox STATIC not found (initrd for required) -> sudo apt-get install -y busybox-static"
if ldd /bin/busybox >/dev/null 2>&1; then warn "/bin/busybox is dynamically linked (it will work, but static is better: busybox-static)"; else ok "/bin/busybox static"; fi
need blkid
need parted
needf /sbin/mkfs.ext4
needf /usr/sbin/grub-install
echo "-- kernel + modules --"
found=0
for v in /boot/vmlinuz-*; do [ -e "$v" ] || continue; k=${v##*/vmlinuz-}; found=1
  if [ -d "/usr/lib/modules/$k" ] || [ -d "/lib/modules/$k" ]; then ok "$v (+modules $k)"; else bad "no /lib/modules/$k for $v"; fi
done
[ "$found" = 1 ] || bad "/boot/vmlinuz-* not found - install the linux-image package (or build one with: make kernel)"
echo "-- for running the tests (optional) --"
need qemu-system-x86_64 || true
[ -e /usr/share/OVMF/OVMF_CODE_4M.fd ] || [ -e /usr/share/OVMF/OVMF_CODE.fd ] && ok "OVMF (UEFI test)" || warn "OVMF not -> 'make run-efi' skip will"
echo "-- root powers (needed for some build steps) --"
if [ "$(id -u)" = 0 ]; then ok "you are root"; elif command -v sudo >/dev/null 2>&1; then ok "sudo available"; else warn "no sudo - some steps (depmod/losetup tests) must be run manually"; fi
echo
if [ "$miss" = 0 ]; then
  echo "all ready -> make iso (then: make run / make test)"
else
  echo "$miss things missing. Install (Debian/Ubuntu):"
  cat <<'PKG'
  sudo apt-get update
  sudo apt-get install -y build-essential make squashfs-tools xorriso grub-common \
      grub-pc-bin grub-efi-amd64-bin grub2-common mtools dosfstools e2fsprogs \
      util-linux cpio gzip busybox-static linux-image-amd64 kmod
  # for tests (optional)
  sudo apt-get install -y qemu-system-x86 ovmf
PKG
  echo "Fedora: sudo dnf install gcc make squashfs-tools xorriso grub2-pc-modules grub2-efi-ia32-modules \\"
  echo "            grub2-tools-extra mtools dosfstools e2fsprogs util-linux cpio busybox-static kernel-devel \\"
  echo "            qemu-system-x86 ovmf"
  echo "Arch:   sudo pacman -S base-devel squashfs-tools xorriso grub mtools dosfstools e2fsprogs util-linux cpio busybox linux qemu-full"
  exit 1
fi

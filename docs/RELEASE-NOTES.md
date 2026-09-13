# pk's OS 1.1

A small Linux you build yourself and that boots on a normal PC - live from a USB stick
or installed to disk - with networking, a Wayland desktop, real application support and
user management. Built entirely from source on your machine.

## Which file to download

| File | Size | Use |
|---|---|---|
| `pkos-1.1-apps.iso` | 648503296 bytes (618.5 MiB) | **this one.** Base live system + Debian app runtime + desktop + Wine + essentials |
| `pkos-1.1.iso` | 97820672 bytes (93.3 MiB) | console-only live system + installer + device modules (add a runtime later) |

Write it to a stick (destroys the stick's data):

```sh
sudo dd if=pkos-1.1-apps.iso of=/dev/sdX bs=8M status=progress oflag=sync
# or: sudo tools/write-usb.sh /dev/sdX pkos-1.1-apps.iso
```

Boot in BIOS or UEFI mode (Secure Boot off). Log in as `root` / `pk`, then `pk-help`.
Prefer a normal account: boot with `pk_user=bob pk_userpw=bob` added to the GRUB line.

## What is in this release

* **Basic software is pre-installed** in the apps image - 55 commands verified present at
  build time (`pkos-1.1-essentials.txt`, and a boot marker:
  `### PK: ESSENTIALS-OK (count=55 missing=0) ###`):
  editors (`vim`, `nano`), `htop tmux rsync git make python3 man bc jq file tree pv ncdu
  strace lsof`, archives (`zip unzip 7z xz`), network (`ip ping dig nslookup iperf3
  ethtool socat ssh curl wget`), hardware (`lspci lsusb dmidecode`), PDF/images/audio
  (`pdftotext`, `xpdf`, `sxiv`, `mpg123`), a browser (`dillo`), and **Wi-Fi/Bluetooth
  tools** (`wpa_cli`, `wpa_supplicant`, `iw`, `iwlist`, `rfkill`, `bluetoothctl`).
* **Networking** `pk-net dhcp` / boot option `pk_net=dhcp`; `pk-wifi connect <ssid> <pw>`;
  `pk-ssh start` (dropbear).
* **Desktop on the real screen**: weston/Wayland on KMS with **seatd** as session manager -
  the compositor takes the active VT, gets `/dev/dri` and `/dev/input`;
  `pk-desktop start|status|app|vnc|shot`, XWayland for X11 apps, llvmpipe when there is no
  accelerated GL.
* **Users and devices**: `pk-user add/del/passwd/autologin/doctor`; new users land in
  `audio input video render dialout seat`, so sound, mouse/keyboard and DRM work
  unprivileged. `pk-devperms` keeps `/dev` modes right for late-binding drivers.
* **Applications**: `pk-run` for ELF, scripts, `.deb`, `.rpm`, AppImage, `.jar`, and Windows
  `.exe`/`.msi` through Wine; foreign-arch Linux binaries (arm64, riscv64, ppc64le,
  s390x) via `qemu-user` + `pk-binfmt`. `pk-get install -y <pkg>` = Debian's apt inside the
  runtime, which cannot damage the base image.
* **Persistence and install**: `pk-persist` + `persistent` boot option on the stick;
  `pk-install` writes GPT + EFI + `/boot` + ext4 (journaling) + GRUB and can create a user.
* **Hardware coverage**: GPU/KMS (i915, nouveau, radeon, vmwgfx, vboxvideo, qxl, bochs,
  virtio, ast, mgag200, simpledrm/efifb), storage, Ethernet + Wi-Fi driver modules,
  sound (`snd-hda-intel`, `snd-ac97`, `snd-usb-audio`), Bluetooth, UVC webcam, `hwmon`
  sensors, batteries, backlight, Thunderbolt/USB-C PHY.
* **Hardware self-test**: `pk-check [--save --gui --apps --users --speed --all]` prints one
  row per subsystem, with the reason; boot leaves `### PK: … ###` markers in `dmesg`.
* **Documentation in English**, 13 files in `docs/` plus a cheat sheet inside the image. The text on
  the screen is English as well: GRUB menu titles, every boot/installer/self-test line, every
  `pk-check` row, and the printed output of every shipped tool including `pk-run`, `pk-net`,
  `pk-wifi` and `pk-ios` (developer comments inside the scripts and the QA script's own labels
  are still Hinglish).
* Reproducible builds + payload manifests: `REPRODUCIBLE=1 make kit`, `make verify`.

## QA

`make test` (8 QEMU stages: live, media variants, install, installed boot, toram, UEFI,
persistence+net+ssh, apps+pendrive kit) → `QA PASS (78 checks ok)`;
`make gui-test` → `QA PASS (24 checks ok)` on the tree tagged here.

## Honest limits

iOS `.ipa` files cannot run here (Mach-O/XNU + Apple code signing + closed UIKit) - see
`docs/IOS-ANDROID.md` for the routes that do work; Android needs Waydroid/binder or a VM.
`amdgpu` and `xe` drivers are not shipped (firmware size) - console + VNC desktop instead,
or add them to `config/live-modules.txt`. No systemd, no LUKS in the installer, Secure
Boot unsigned. Audio output, real Wi-Fi association and webcam capture could not be
proven in this CI (QEMU has no audio backend and no wireless hardware) - the docs list the
exact commands to check them on your machine.

## Build it yourself

```sh
git clone https://github.com/risky-chokra/pk-os.git && cd pkos
sudo apt install -y kmod squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin \
     grub2-common dosfstools parted e2fsprogs util-linux dropbear busybox-static \
     qemu-system-x86 qemu-utils debootstrap mtools
make doctor && make kit && make test
```

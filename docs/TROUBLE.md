# Troubleshooting

Rule of thumb: `dmesg | grep '### PK'` (or the serial log) tells you which stage failed.
Each marker below has a matching fix. `pk-check --save` writes the same information to
`/run/pk/check.txt`.

## It does not boot from the stick

| Symptom | Cause and fix |
|---|---|
| USB does not appear in the boot menu | stick written to a partition instead of the whole disk → `dd` to `/dev/sdX`, not `/dev/sdX1`. Some firmwares hide "USB HDD" until Legacy/CSM is enabled |
| GRUB appears, then `error: you need to load the kernel first` | ISO not hybrid-complete → rewrite from `manifest.txt`'s SHA-256 verified file, and try the other firmware mode (UEFI ↔ BIOS) |
| Kernel starts, then panic `VFS: Unable to mount root fs` | live medium not found → add `pk_media=/dev/sdb` (check the real name in the panic list) or `rootdelay=8` for slow USB controllers |
| Stops in `(initramfs)` prompt | boot with `break=mount pk_fsdebug=1`; inside: `ls /dev/sd*`, `blkid`, then `mount -t iso9660 /dev/sr0 /iso` to see the error |
| Screen stays black after GRUB, but SSH works | display handling problem, not a boot problem → boot `pk_display=off`, connect with `pk-ssh start` + ssh; `pk-tune`/`pk-x` still usable |
| Freezes with `amdgpu`/`i915`/`nouveau` errors | add `nomodeset` to the boot line → falls back to `simpledrm`/VESA, still gets a desktop via `pk-desktop vnc 5900` |

## No screen output / no desktop

| Marker or message | Meaning and action |
|---|---|
| `DISPLAY-TEXTONLY` | no KMS device — the driver for this GPU is not in the live image (expected on `amdgpu`/`xe` machines). Console + VNC desktop work; see [REAL-PC.md](REAL-PC.md) for the GPU note |
| `DISPLAY-KMS (drm=1 …)` but black screen | weston took another VT → look for `DESKTOP-VTMISMATCH (want=ttyX active=ttyY)`; press `Ctrl-Alt-F<X>`, or `pk-desktop vnc 5900` |
| `DESKTOP-NO-RUNTIME` | the apps runtime is not attached, so weston is not installed → `pk-runtime status`, then `make apps-iso` or `pk-runtime --setup <file>` |
| `SEATD-SKIP (…)` / `SEATD-FAIL (…)` | session manager unavailable: weston then cannot own the VT. `pk-seatd start`, `tail /run/pk/seatd.log`. `pk_seatd=off` deliberately skips it |
| `DESKTOP-XVFB (headless fallback)` | no DRM device, so an Xvfb session was started: reachable over VNC, not on the monitor |
| Screen blank 1 minute in | `consoleblank=0` is in the default `KERNEL_CMDLINE`; if someone removed it, add it back or run `pk-x`'s display hook via `pk-desktop start` |
| Desktop shows no text | fonts/icons missing in a custom runtime → rebuild with `make runtime-desktop` (it ships `fonts-dejavu-core` + `adwaita-icon-theme`) |
| QEMU shows a black window with `-vga vmware` | QEMU's SVGA is rejected by the kernel → use `-vga std`, `-vga virtio` (with `edid=on`) or `-device qxl-vga` |
| `screendump` shows the text console although the desktop runs | with `-display none`/virtio-gpu the QEMU framebuffer is stale → use `pk-desktop shot` inside the guest |

## Networking

| Symptom | Fix |
|---|---|
| `pk_net=dhcp` did nothing | `pk-check` row `net`/`driver` — the NIC driver is a module: `lsmod \| grep -i e1000` ; coldplug loads it: `mdev -s` (or `pk-devperms --watch` to re-apply groups to late nodes). `dmesg \| grep -i firmware` for cards that need a firmware blob |
| DHCP times out (VM) | the QEMU user-mode DHCP lease can be slow: `pk-net dhcp` again, or `pk-net dhcp` again, or set it by hand inside the session: `ifconfig eth0 10.0.2.15/24; route add default gw 10.0.2.2` |
| Wi-Fi interface not listed | `rfkill list`, `ip link` — the driver may be a module (`iwlwifi`, `ath9k`…): `modprobe iwlwifi`; the firmware pack is opt-in in the runtime (`pk-get install -y firmware-iwlwifi` on Debian-firmware-enabled mirrors, else copy the blob to `/lib/firmware`) |
| `pk-wifi connect` fails at 4-way handshake | wrong PSK (quotes!) or the AP needs a PMF setting: `tail /run/pk/wifi-boot.log`, then `pk-wifi status` (driver + firmware + rfkill) and `pk-wifi scan` |
| SSH refused | `pk-ssh status`; root login needs a password: `pk_rootpw=secret` at boot or `passwd` in the session |

## Applications

| Symptom | Fix |
|---|---|
| `pk-get: no such file or directory` | runtime not attached → `pk-runtime status`, `pk-runtime start` |
| `pk-chroot` says permission denied | chroot helpers are root-only by design; `su -` first (live password `pk`) |
| `.deb` says "dependency problems" | the runtime is `minbase`-style: `pk-get update && pk-get install -y <the-missing-lib>` — or let apt resolve it: `pk-get install -y /path/app.deb` |
| App starts and instantly exits | run it in the foreground to see its error: `pk-run --gui <app>` / `pk-chroot /usr/bin/<app>` |
| Windows app: `wine: unknown ABI` or crash | 32-bit prefixes need `wine32` (`pk-get install -y wine32` on multiarch) — 64-bit-only Wine cannot run a 32-bit installer |
| ARM/RISC-V binary: `cannot execute binary file` | `pk-binfmt register` (needs the runtime's qemu-user), check `pk-binfmt status` |
| `.ipa` | impossible natively — read `pk-ios why`; routes in [IOS-ANDROID.md](IOS-ANDROID.md) |
| Android `.apk` opens but crashes | `pk-android doctor` → needs binder + Waydroid; without a Waydroid image there is no Android runtime |

## Installation

| Symptom | Fix |
|---|---|
| `INSTALL-DEPS` / "installer tools missing" | you booted the base image without the runtime: `parted`/`grub` come from the runtime → use `pkos-apps.iso`, or `pk-runtime start` first |
| Installer complains the disk is in use | the stick itself is the live medium: choose the internal disk explicitly (`--target=/dev/sda`) and check `lsblk`, swap/RAID: `pk-install --info` |
| Installed system boots to GRUB prompt | GRUB was installed for the wrong mode → reboot the stick and run `pk-install --target=<dev> --layout=efi` (or `--layout=bios`) |
| No network after install | installed systems use the same `pk-net`; add it at first boot: `pk-net dhcp`, then `pk-boot` persists it via `/etc/default/pk` |
| Forgot the installed password | boot the stick, `pk-chroot` is for the runtime; for the installed root: mount it and edit `/etc/shadow` with `pk-user` against the mounted tree (see `pk-user doctor`) |

## Getting a bug report right

```sh
pk-info > /tmp/pk-info.txt
pk-check --save --users ; cp /run/pk/check.txt /tmp/
cp /run/pk/x-weston.log /run/pk/seatd.log /run/pk/desktop.log /tmp/ 2>/dev/null
dmesg > /tmp/dmesg.txt
pk-desktop shot /tmp/desktop.png 2>/dev/null
```
Attach `/tmp` (tar it) plus the exact boot line you used.

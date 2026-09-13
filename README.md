# pk's OS

A small, self-contained Linux distribution that you build on your own PC and that
boots on ordinary x86-64 hardware — from a live USB stick or installed permanently to
disk — with working networking, a graphical desktop, real application support
(Linux native, Windows through Wine, plus app-runtime packaging) and user management.

Everything is generated from source on your machine: kernel modules and packages are
collected from the host and from a Debian `debootstrap` rootfs. No pre-built image is
downloaded, so the result is auditable and reproducible.

```
build on your PC  ->  test in QEMU/VirtualBox  ->  write to a USB stick  ->  install to disk
```

## Status

| Area | State |
|---|---|
| Boot (BIOS + UEFI, hybrid ISO, `dd`-able to USB) | working, covered by automated QA |
| Live session (squashfs read-only + RAM overlay) | working |
| Networking (`pk_net=dhcp`, mdev-triggered driver load, Wi-Fi helper) | working |
| Desktop (weston/Wayland on KMS, `seatd` session, VT takeover, XWayland) | working |
| Linux apps (ELF, scripts, `.deb`, `.rpm`, AppImage, `.jar`, apt via runtime) | working |
| Foreign-arch Linux binaries (ARM/RISC-V via `qemu-user` + binfmt) | working when enabled |
| Windows apps (`.exe` via Wine) | working (Wine prefix per app) |
| iOS (`.ipa`) / Android (`.apk`) native execution | not possible — see [docs/IOS-ANDROID.md](docs/IOS-ANDROID.md) for the diagnostics and the workable routes |
| Permanent install (GPT + ext4 + LVM-free, GRUB, first-boot) | working |
| Persistence on the stick (`persistent` option, home/root overlays) | working |
| Users (`pk-user add/del/…`, autologin, device-group access) | working |
| Device support (GPU KMS, audio, input, webcam, sensors, battery, USB, Bluetooth modules shipped) | working; per-hardware validation is your test |
| Automated QA | `make test` (full suite, 8 stages) and `make gui-test` — counts in [STATUS.md](STATUS.md) |
| Basic software in the image | 55 commands pre-installed in the apps image and verified at build time (`docs/APPS.md` §2) |
| Language of everything you read | English - documentation, every tool's help and its printed messages, the login banner, the GRUB boot menu, and everything shown while booting, installing, launching apps and self-testing (guarded by `tools/publish.sh --docs-only`) |
| Standard command names | `nano`, `git`, `apt`, `python3`, `ssh`, `ifconfig`, `useradd`, `startx` ... work in the live system - `pk-std` runs the live binary if there is one, otherwise maps the name to the tool that does the job or dispatches it into the App Runtime |

## Requirements

* Build host: Debian 12/13 or Ubuntu 22.04/24.04 (amd64), `sudo`, ~15 GB free disk, 4 GB RAM (8 GB is nicer while `debootstrap` runs).
* Target PC: any x86-64 machine with BIOS or UEFI firmware.
  * live base image: 768 MB RAM is enough (QA runs the whole suite at 640 MB)
  * live image with the app runtime + desktop: 2 GB RAM recommended
  * disk for install: 8 GB minimum, 20 GB comfortable
* ISO sizes: base live ≈ 93 MiB (98 MB), live + app runtime ≈ 619 MiB (649 MB) (the runtime itself is 525 MB compressed). Exact byte counts and SHA-256 for every published build are in the release assets (`manifest*.txt`).

## Quick start

```sh
# 1. build the base live ISO
sudo apt install -y kmod squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin \
                    grub2-common dosfstools parted e2fsprogs util-linux dropbear \
                    busybox-static qemu-system-x86 qemu-utils debootstrap mtools
make doctor          # checks the toolchain, tells you what is missing
make iso             # -> build/pkos.iso

# 2. boot it in an emulator (fast feedback loop)
make run             # QEMU with serial console; add 'make gui-test' for the desktop path

# 3. build the runtime + the combined ISO (apps, desktop, Wine, the essential tools)
make runtime-desktop
make apps-iso        # -> build/pkos-apps.iso

# 4. write to a USB stick (this destroys the stick's data)
make usb USB=/dev/sdX
# or: sudo dd if=build/pkos-apps.iso of=/dev/sdX bs=8M status=progress oflag=sync
sudo tools/verify-usb.sh /dev/sdX

# 5. install permanently (boot the stick, log in, then)
pk-install --target=ask --user=ravi
```

Full walkthrough: [docs/BUILD.md](docs/BUILD.md) → [docs/VM-TEST.md](docs/VM-TEST.md) →
[docs/PENDRIVE.md](docs/PENDRIVE.md) → [docs/REAL-PC.md](docs/REAL-PC.md).

## What you get in the live system

| Command | What it does |
|---|---|
| `pk-help` | one-page list of everything |
| `pk-info` | boot mode, media, kernel, mounts, IP, runtime state |
| `pk-check [--gui --apps --users --speed --all]` | self-test of hardware + OS: display, GPU, audio, input, serial, webcam, network, storage speed, users, apps, session manager |
| `pk-net dhcp \| status \| down` | networking (`pk_net=dhcp` at boot) |
| `pk-wifi scan\|connect <ssid> <pw>` | Wi-Fi (WPA supplicant front-end) |
| `pk-ssh on\|off\|status` | dropbear SSH server (`pk_ssh=on` at boot) |
| `pk-desktop start\|status\|app X\|vnc PORT\|shot [file]` | graphical session control |
| `pk-x start\|stop\|status [weston\|Xorg\|Xvfb]` | the display server layer under it |
| `pk-seatd start\|stop\|status` | seatd session manager (gives weston the VT, DRM and input devices) |
| `pk-user list\|info\|add\|del\|passwd\|autologin\|doctor` | local users, device groups, console autologin |
| `pk-keymap <layout>` | keyboard layout for console and GUI |
| `pk-run <file-or-url>`, `pk-shell`, `pk-get install -y <pkg>`, `pk-chroot` | app layer (Debian runtime, its own apt, its own prefix) |
| `pk-runtime start\|status\|attach…` | where the app runtime lives (ISO/partition/file) |
| `pk-ios`, `pk-android` | diagnostics + the realistic routes for `.ipa` / `.apk` |
| `pk-persist [/dev/sdX]`, `persistent` boot option | keep changes on the stick |
| `pk-tune report\|desktop\|hybrid` | boot-time tuning (governor, EPP, I/O scheduler, cgroups) |
| `pk-binfmt`, `pk-vm` | foreign-architecture execution, local QEMU helper |
| `pk-install` | permanent install to disk |

### Boot options

Passed on the kernel command line (edit the GRUB entry with `e`, or add them to
`KERNEL_CMDLINE` when building):

```
pk_media=<dev>        force which medium is the live ISO          pk_iso=<path>   ISO file to boot instead of the block device
pk_verify=1|require   check the ISO/USB checksum                 pk_fsdebug=1    extra filesystem diagnostics
rootdelay=N           wait for slow USB controllers                pk_silent       quieter boot
pk_net=dhcp           DHCP at boot                                 pk_ssh=on|off   dropbear SSH
pk_keymap=<layout>    console + XKB layout                         pk_wifi=<ssid>:<pw>
pk_desktop=1          start the graphical session at boot          pk_display=off  skip display handling
pk_seatd=on|off       seatd session manager                        pk_tune=report|desktop|hybrid
pk_swap=<MB>|auto|off swap file (default off)                       pk_check=1|gui  run self-test at boot
pk_user=<name>        create/use this user + console autologin      pk_userpw=<pw>  its password
pk_rootpw=<pw>        root password for the live session            pk_halt pk_poweroff
pk_install=<dev>|ask  install to disk (see pk-install)              pk_install_user=<name> pk_install_userpw=<pw>
persistent[=<label>]  keep changes on the stick                     toram           copy the ISO to RAM
pk_apps_get=…         fetch an extra .sqfs at boot                  pk_runtime=off|auto|<dev|file>
pk_run=<cmd>          run one shell command at the end of boot and print it to the console
                      (space = '+', separate commands with '!' — ';' is a GRUB separator)
break=mount single    initramfs debugging                           pk_selftest     the QA self-test hooks
```

## Documentation

| File | Contents |
|---|---|
| [docs/BUILD.md](docs/BUILD.md) | build host setup, every `make` target, config knobs, reproducible builds, publishing a release |
| [docs/VM-TEST.md](docs/VM-TEST.md) | QEMU / VirtualBox recipes, expected boot markers, display matrix, desktop + users + devices test sheet |
| [docs/PENDRIVE.md](docs/PENDRIVE.md) | writing the stick, what to do on the target PC, per-symptom kit commands |
| [docs/REAL-PC.md](docs/REAL-PC.md) | real hardware checklist (display, audio, input, Wi-Fi, users, screenshot) |
| [docs/APPS.md](docs/APPS.md) | the app runtime: apt, `.deb`/`.rpm`/AppImage/`.jar`, Windows via Wine, foreign arch |
| [docs/IOS-ANDROID.md](docs/IOS-ANDROID.md) | why `.ipa`/`.apk` cannot simply run, and the routes that do work |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | initramfs, live overlay, runtime attach, session/desktop, device policy |
| [docs/PERSISTENCE.md](docs/PERSISTENCE.md) | `persistent`, home/root overlays, install semantics |
| [docs/TROUBLE.md](docs/TROUBLE.md) | symptoms → markers → fixes (black screen, no network, no desktop, boot failures) |
| [docs/KERNEL.md](docs/KERNEL.md) | building your own kernel + modules instead of the host kernel |
| [docs/COMPARE.md](docs/COMPARE.md) | how this differs from other minimal/live distributions |
| [docs/RELEASE.md](docs/RELEASE.md) | what is in a release, asset list, checksums, how to publish |
| [docs/RELEASE-NOTES.md](docs/RELEASE-NOTES.md) | the text published with the GitHub release (release notes) |
| [STATUS.md](STATUS.md) | release notes + engineering log: what was fixed, what was measured, what is open |

## Honest limits

* Not a general-purpose distribution: it is a small, readable OS whose pieces are
  deliberately few. Debian packages come from the optional app runtime, not from the base image.
* iOS apps cannot run (code signing, Mach-O, no legal runtime); Android apps run only
  through an emulator/ARC-style stack, never natively on this kernel by default.
* `amdgpu` and `intel/xe` GPU drivers are intentionally not shipped (firmware size);
  KMS works on VMware/VirtualBox/qxl/bochs/virtio/AST/Matrox/Intel(i915)/Nouveau/Radeon.
  Audio, Bluetooth and webcam modules are shipped, but a specific card may still need
  firmware — the firmware pack is opt-in.
* Secure Boot is not signed; use BIOS/UEFI with Secure Boot off, or `mokutil` on your own.
* Wayland sessions run as the live user (root by default). A non-root Wayland session
  works through seatd, but the app runtime's `chroot` helpers are root-only by design.

## License

The scripts, initramfs, boot hooks and documentation in this repository are MIT
licensed (see [LICENSE](LICENSE)). The kernel, busybox, Debian packages, Wine, Mesa and
every other component keep their own licences — a release ships sources for all of them
through the build recipe rather than redistributing opaque binaries.

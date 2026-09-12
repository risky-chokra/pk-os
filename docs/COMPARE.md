# How pk's OS compares

This is not trying to be Debian. It is a small, readable, *self-built* live OS whose
feature set is chosen around four things a personal OS actually needs: boot anywhere,
run real apps, show a desktop, manage users and devices.

| Capability | pk's OS | Typical minimal live distro (e.g. TinyCore, Alpine-style) | A big live ISO (Debian/Ubuntu live) |
|---|---|---|---|
| Built from source on your PC in one command | `make kit` ✅ | ❌ (download pre-built image) | ❌ (rebuild is a project of its own) |
| Reproducible build + payload manifest | `REPRODUCIBLE=1`, `manifest*.txt` ✅ | ❌ | partly |
| Base image size | ≈ 95 MB ✅ | 20-300 MB | 1-3 GB ❌ |
| Boots BIOS **and** UEFI from one hybrid ISO, `dd`-able | ✅ (QA checks both) | often one of them | ✅ |
| Installer to disk (GPT+EFI+GRUB+user, journaling) | ✅ `pk-install` | usually ❌ | ✅ |
| Persistence on the same stick | ✅ `pk-persist` + `persistent` | partly | live-rw only |
| App ecosystem without changing the OS | separate Debian runtime at `/opt/pk` with its own apt/Wine ✅ | package set is fixed ❌ | system apt ✅ but the OS *is* the packages |
| `.exe` support | Wine in the runtime ✅ | ❌ | manual |
| Foreign-arch Linux ELF (arm64, riscv64…) | `pk-binfmt` + `qemu-user` ✅ | ❌ | qemu-user-static, manual |
| Windows `.msi` installers | via Wine ✅ | ❌ | manual |
| iOS/Android apps | honest diagnostics + real routes (`pk-ios`, `pk-android`) ✅ (no false promise) | ❌ / silence | ❌ / silence |
| Wayland desktop without systemd | weston + **seatd**, VT takeover ✅ | ❌ or X11 only | ✅ but systemd-logind |
| Software rendered/visible by default | fonts, icons, mesa (llvmpipe), XWayland in the runtime ✅ | ❌ | ✅ |
| User/device management | `pk-user` + mdev groups (`audio input video render dialout seat`) ✅ | root-only ❌ | full (logind) ✅ |
| Boot-time self-test with markers | `pk-check`, `### PK: … ###`, 70+ automated QA checks ✅ | ❌ | ❌ |
| init system | busybox `inittab` + `S*` hooks (readable, re-runnable) | busybox | systemd (large) |
| Everything inside one image (frugal boot of an ISO file) | ✅ `pk_iso=` + FAT32 frugal layout | ❌ | ❌ |

Where pk's OS is deliberately **weaker** (so the table is not marketing):
* no systemd → no `systemctl`, no socket activation, no logind sessions for normal users
  beyond seatd's lease, no `.timer` units;
* no package manager in the base image: the base is busybox + your kernel; Debian apt
  lives in the runtime, so it is per-runtime and needs root;
* driver coverage is a *list you edit* (`config/live-modules.txt`), not a full kernel
  module set: `amdgpu`/`xe` are intentionally absent;
* no Anaconda/Calamares-style installer UI: `pk-install` is a careful script with
  `--info` and `--yes`, plus an autoinstall hook when a real installer UI is wanted;
* no cross-architecture ISO: the live image is amd64 (arm64 hardware can be supported by
  building on that machine — the layout already boots `pk_iso=` frugally);
* no LUKS/full-disk encryption in the installer yet (the runtime can mount it manually),
  and no OTA updater: you flash a new image or `git pull && make kit`.

If you need the full Debian experience, run Debian. If you want to *own* the OS — read
every file, boot it on a 2009 netbook and on a 2024 mini-PC, run a Windows installer
from a USB stick, and know exactly which marker to grep when something fails — this is
the project for that.

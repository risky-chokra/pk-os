# Building pk's OS

## 1. Build host

Debian 12/13 or Ubuntu 22.04/24.04, amd64, with `sudo` and roughly 15 GB free disk.

```sh
sudo apt update
sudo apt install -y kmod squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin \
                    grub2-common dosfstools parted e2fsprogs util-linux dropbear \
                    busybox-static qemu-system-x86 qemu-utils debootstrap mtools file
make doctor        # prints exactly what is missing (and how to install it)
```

`make doctor` also checks for `linux-image-amd64` (the live image reuses the host
kernel and its `/lib/modules` set). If your host has no modules directory, install a
kernel package or build your own (see [KERNEL.md](KERNEL.md)).

## 2. Targets

| Target | Result |
|---|---|
| `make iso` | `build/pkos.iso` — base live system (busybox userland, no app runtime) |
| `make runtime` | `build/pk-runtime.sqfs` — Debian app runtime, lean package set |
| `make runtime-desktop` | the same with GUI stack: weston, XWayland, xterm, mesa/llvmpipe, seatd, alsa-utils and the essential command-line tools |
| `make apps-iso` | `build/pkos-apps.iso` — base ISO with the runtime inside it (single-file "everything" image) |
| `make kit` | both ISOs + `manifest.txt` + `manifest-apps.txt` + a source bundle: the release set |
| `make verify` | `tools/verify-usb.sh --iso` on the built ISO: hybrid layout, protective GPT, payload hashes vs `manifest.txt` |
| `make test` | end-to-end QA in QEMU: 8 stages (live, media variants, install, installed boot, toram, UEFI, persistence + net + ssh, apps, USB kit) |
| `make gui-test` | the kit stage with the graphical session enabled (desktop, seatd, users, screenshot rows) |
| `make usb USB=/dev/sdX` | writes the ISO to a stick and verifies it |
| `make kernel` | builds a private kernel with `scripts/build-kernel` (optional) |
| `make bundle` | `pkos-<ver>.bundle` (git bundle) + `pkos-<ver>-src.tar.gz` |
| `make run`, `make run-tty`, `make run-efi` | boot the fresh ISO in QEMU (GUI, serial-only, UEFI) |
| `make clean` / `make clean-rootfs` / `make clean-runtime` / `deepclean` | remove build state |

Typical full build:

```sh
make kit                       # ≈ 10 minutes, mostly debootstrap
make test                      # QA on the base ISO
PK_TEST_GUI=1 make gui-test    # QA including the desktop session
```

Rebuild a single layer after editing the live tree:

```sh
rm -f build/work/.stamps/* && make iso            # rootfs + initrd + ISO
make runtime-desktop && rm -f build/work/.stamps/squash && make apps-iso   # runtime changed
```

## 3. Configuration

`config/live.conf` is sourced by every script:

```sh
OS_NAME="pk's OS"      OS_VERSION=1.0      OS_ID=pkos     ISO_LABEL=PKOS
HOSTNAME=pk            LIVE_USER=root      LIVE_PASS=pk
SQUASH_COMP=auto       # auto | zstd | xz | lz4 | gzip
KERNEL_CMDLINE="quiet loglevel=3 consoleblank=0 vt.global_cursor_default=1"
```

Other knobs: `config/live-bins.txt` (host binaries copied into the live image; their
shared libraries are collected automatically), `config/live-modules.txt` (which kernel
modules the live image ships — GPU, storage, network, sound, bluetooth, webcam,
sensors…), `init/grub.cfg` (the GRUB menu: live, live+serial, safe mode, desktop+apps,
install entries).

Runtime package sets live in `scripts/make-runtime` (`lean`, `full`, `desktop`, `dev`
variants; `--variant=…`). Everything not in the base image can be added at runtime with
`pk-get install -y <pkg>` (that is Debian's apt inside the runtime).

## 4. Reproducibility

```sh
REPRODUCIBLE=1 make kit
```

sets `SOURCE_DATE_EPOCH`, fixes file ordering and uses a deterministic GRUB/ISO layout,
so two builds of the same commit produce byte-identical ISOs (the runtime squashfs is
the only part that depends on the current Debian mirror state). Publish builds made this
way. `build/manifest*.txt` contains sizes, SHA-256 of every artifact and the git commit.

## 5. Publishing

`tools/publish.sh` creates the GitHub repository, pushes `main`, tags the release and
uploads the artifacts:

```sh
export GITHUB_TOKEN=ghp_…            # classic PAT with the 'repo' scope (fine-grained
                                     # tokens cannot create repositories)
OWNER=risky-chokra REPO=pk-os VERSION=1.1 TAG=v1.1 make kit
OWNER=risky-chokra REPO=pk-os VERSION=1.1 TAG=v1.1 tools/publish.sh
```
`tools/publish.sh` first runs a documentation language guard (`--docs-only` runs just
that): no Hindi/Hinglish or Devanagari may remain in README/STATUS/`docs/*.md`.

See [RELEASE.md](RELEASE.md) for the exact asset list and the notes template.

## 6. Build problems worth knowing

| Symptom | Cause / fix |
|---|---|
| `grub-mkrescue: No space left on device` | small `/tmp`; the build already exports `TMPDIR=build/work/tmp`, so free space on the *project* filesystem |
| `EACCES` while writing `$SUIT/etc` | the runtime tree was created by a previous `sudo make runtime`; run `make clean-runtime` or keep using sudo consistently |
| ISO did not change after editing `init/grub.cfg` or `KERNEL_CMDLINE` | fixed in this tree (the Makefile depends on both), but `rm -f build/work/.stamps/*` is the manual escape hatch |
| `qemu-system-x86_64: could not set guest RAM` | VM size larger than host RAM + swap; QA uses 640–2048 MB |
| Live boot stops in initramfs | boot with `break=mount pk_fsdebug=1` and read the printed mount diagnostics |

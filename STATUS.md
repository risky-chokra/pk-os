# pk's OS - release notes and verification log

English-only from here on: the earlier per-round engineering log was in Hinglish and has
been folded into this document (the original wording stays in the git history).

## 1. This release

| Item | Value |
|---|---|
| Version | 1.1 (tag `v1.1`) |
| Base live ISO | `build/pkos.iso` — 97820672 bytes (93.3 MiB) |
| Apps ISO (recommended) | `build/pkos-apps.iso` — 648503296 bytes (618.5 MiB) |
| App runtime | `build/pk-runtime.sqfs` — 550645760 bytes (525.1 MiB), zstd, Debian bookworm `desktop` variant |
| Essential commands verified in the runtime | `count=55 missing=0` (`/etc/pk-essentials.txt`, published as a release asset) |
| Documentation | English only — README, all 13 `docs/*.md`, this file, the in-image cheat sheet, `pk-help`, `/etc/motd`, `/etc/issue`; guarded by `tools/publish.sh --docs-only` |
| On-screen text | English everywhere - the 13 GRUB menu titles, the initramfs handoff lines, `pk-boot`/`pk-install`/`pk-runtime` progress and every error they raise, all 53 `pk-check` rows, and the printed messages of every shipped tool (`pk-run`, `pk-x`, `pk-desktop`, `pk-user`, `pk-net`, `pk-wifi`, `pk-tune`, `pk-ios`, `pk-android`, ...). Only in-code developer comments and the QA script's own pass/fail labels are Hinglish |
| Automated QA | `make test` = **QA PASS (78 checks ok)**, `make gui-test` = **QA PASS (24 checks ok)** on this exact tree |
| License | MIT (our code); bundled components keep their own licences |

The apps image got *smaller* than the previous release (658 MiB → 618 MiB) while gaining
~55 packages: the runtime's doc/man/locale/apt-cache trim now runs **after** the
`debootstrap` stage instead of before it, so nothing a later install brought back was
left in the image.

## 2. What changed in this round

1. **Essential software pre-installed** (`scripts/make-runtime`): the runtime now ships
   `nano vim less htop procps psmisc which file tree pv tmux rsync git make curl wget
   openssh-client jq zip unzip p7zip-full xz-utils patch diffutils bc ncdu strace lsof
   iputils-ping iproute2 dnsutils iperf3 ethtool socat dialog pciutils usbutils dmidecode
   python3 man-db bash-completion locales poppler-utils xdg-utils gnupg
   openssh-sftp-server` plus, for the desktop variant, `dillo sxiv mupdf-tools xpdf
   mpg123 wpasupplicant iw wireless-regdb rfkill wireless-tools bluez bluez-obexd
   pinentry-curses`.
   Installed with `apt-get install -y --no-install-recommends` inside the runtime (a
   `debootstrap --include` list cannot carry them: `minbase` only resolves
   required/important packages - that exact failure, `E: Couldn't find these debs: which
   crda watch`, is why the install moved to apt).
2. **The claim is checked, not asserted**: the build writes `/etc/pk-essentials.txt`
   inside the runtime; every boot turns it into `### PK: ESSENTIALS-OK (count=.. missing=0) ###`
   (`sbin/pk-runtime`), and `make test` asserts both the build record and that marker.
   So `make runtime VARIANT=…` with a broken mirror prints `ESSENTIALS-PARTIAL` and fails QA.
3. **Wi-Fi needs no extra download anymore** - previously the docs told you to
   `pk-get install -y wpasupplicant iw` first; the tools now ship in the image.
4. **Docs rewritten in English** (see §1) and `docs/APPS.md` documents the shipped set,
   `docs/REAL-PC.md` explains what QEMU cannot prove.
5. **Publishing**: `tools/publish.sh` (repo create → push → tag → release → assets →
   verify) and `docs/RELEASE.md`.
6. Trim ordering fix in the runtime build (`var/cache/apt/archives`, `usr/share/doc`,
   `man`, `info`, `i18n`, non-English locales, vim docs are removed after all installs).

## 3. What is proven by `make test` (8 stages)

| Stage | Proves |
|---|---|
| 1 live boot | GRUB→kernel→initrd→squashfs+overlay→init, `BOOT-OK`, `SELFTEST-OK`, payload `VERIFY-OK`, display probe, `USERS-OK`, `MDEV-OK`, swap-guard skip |
| 2 media variants | FAT32 stick layout, frugal ISO-file boot, installer deps, read-only squashfs + visible medium |
| 3 install | partitioning, copy, GRUB, `INSTALL-OK`, `INSTALL-DONE rc=0`, `POWER-OFF`, ext4 journal |
| 4 installed boot | boots from its own GRUB, real `sha-crypt` password, login required (no autologin), `pk_swap` on real disk |
| 5 toram | image copied to RAM, boot continues, self-test passes |
| 6 UEFI (OVMF) | the same ISO boots in UEFI mode |
| 7 persistence + net + ssh | `persistent` overlay, `MDEV-OK`, DHCP `NET-OK (10.0.2.15)`, dropbear `SSH-OK` |
| 8 apps + kit | runtime attach (`RUNTIME-OK`), essentials, `pk-run` dispatch battery (ELF, script, `.deb`, AppImage, foreign arch via qemu-user, `.exe` via Wine), `pk-ios`/`pk-android` honest diagnostics; then `pk-check`, `pk-install` to a second disk, USB-kit rows, desktop/seatd rows |

`PK_TEST_GUI=1 make gui-test` re-runs the last stage with the graphical session enabled
and asserts `SEATD-OK`, `DESKTOP-VT`, `DESKTOP-OK (wayland-1)`, `GUI-APP-OK
(weston-terminal)`, the absence of `DESKTOP-VTMISMATCH`, and `GUI-SHOT-*` (screenshot
path). Run with `PK_TEST_REAL_RUNTIME=1` to also assert the guest marker
`ESSENTIALS-OK` against the real Debian runtime instead of the tiny QA one.

## 4. Measured, not assumed

```
### PK: DISPLAY-KMS (drm=1 driver=bochs-drm|virtio-pci fb=1) ###   (QEMU -vga std / virtio-gpu+EDID)
### PK: SEATD-OK (socket=/run/seatd.sock in runtime, pid=…) ###
### PK: DESKTOP-VT (want=tty1 active=tty1 seatd=1) ###             (no VTMISMATCH on this tree)
### PK: DESKTOP-OK (wayland-1) ###  ### PK: GUI-APP-OK (weston-terminal) ###
### PK: USERS-OK / MDEV-OK / NET-OK (10.0.2.15) / RUNTIME-OK / ESSENTIALS-OK (count=55 missing=0) ###
pk-user add bob --password=…  -> USER-ADD-OK (bob); su -m bob -c id -> 44(video) 63(audio) 108(input) 160(render) 990(seat)
pk-devperms -> /dev/input/event*→input 0660, /dev/dri/card*→video 0660, /dev/snd/*→audio 0660, /dev/ttyS*→dialout
```

## 5. Bugs found and fixed while building this (kept so they do not come back)

| Trap | Symptom | Fix |
|---|---|---|
| `debootstrap --include` + optional packages | `E: Couldn't find these debs: which crda watch`, whole runtime build dies | install extras through apt inside the runtime, after debootstrap |
| hygiene before installs | runtime 897 MiB (docs/man/locale of everything installed later) | trim runs last → 525 MiB |
| absolute `/usr/bin/pk-*` paths | hook silently did nothing (live files are in `/bin`,`/sbin`) | `command -v` everywhere |
| `seatd -u 0` | `SEATD-FAIL (Could not find user by name '0')` | `-u root` (name, not uid) |
| `weston-info` on weston 10 | prints a deprecation notice, QA client test always failed | use a real client (`weston-terminal`) as the proof |
| `weston-screenshooter` on a static desktop | blocks forever | always `timeout 25`, treated as warn not fail |
| busybox has no `adduser`/`deluser` | user tool crashed on the base ISO | `pk-user` edits `/etc/{passwd,group,shadow,gshadow}` itself |
| `openssl passwd -6 --` | hangs reading stdin | always `</dev/null` |
| `sed 's|^u:x:\([0-9]*\)|\1|p'` | returned the rest of the line, not the field | awk field extraction |
| `exec A \|\| exec B` | fallback never ran | explicit attempts with captured output |
| `2>/dev/null` on the compositor attempt | no evidence when weston failed | logs kept in `/run/pk/x-weston.log` and printed |
| `udhcpc` `default.script` mode 644 in git | `NET-FAIL` on a fresh clone | `build-rootfs` chmods 755 at stage time |

## 6. Not verified here (needs your hardware, and we say so in the docs)

* real speaker output (this QEMU build has no audio backend: `-device hda-duplex` →
  `no default audio driver available`, so `/dev/snd/timer` exists but no `pcmC*D*p`);
* Wi-Fi association on a real AP, Bluetooth pairing, webcam capture;
* accelerated GL on Intel/AMD/NVIDIA (driver set is `config/live-modules.txt`;
  `amdgpu`/`xe` intentionally not shipped);
* a non-root Wayland session against the runtime chroot (`pk-chroot` is root-only);
* LUKS/Secure Boot, and `weston.ini` theming.

## 7. Reproducing this release

```sh
git clone https://github.com/risky-chokra/pk-os.git && cd pkos
make doctor                                   # toolchain check; apt list in docs/BUILD.md
export REPRODUCIBLE=1
make runtime-desktop && make kit              # both ISOs + manifests + src tarball + bundle
make test                                     # must print 'QA PASS'
VERSION=1.1 tools/publish.sh                 # needs GITHUB_TOKEN (classic, 'repo' scope)
```

## 8. Repo map

```
Makefile            targets: iso runtime runtime-desktop apps-iso kit test gui-test usb doctor …
init/               initramfs (init), GRUB menu, initramfs module list
config/             live.conf, live-modules.txt, live-bins.txt, live-libs.txt
rootfs/overlay/     the live filesystem: bin/ sbin/ (pk-* tools), etc/ (hooks, mdev.conf, motd, docs)
scripts/            build-rootfs, mk-initrd, mk-squashfs, mk-iso, make-runtime, run-qemu, run-test, manifest, doctor
tools/              write-usb, verify-usb, vm-shot, restore-from-iso, publish, gen-shadow-hash
docs/               BUILD VM-TEST PENDRIVE REAL-PC APPS ARCHITECTURE PERSISTENCE TROUBLE
                    IOS-ANDROID KERNEL COMPARE RELEASE (+ RELEASE-NOTES.md for the release text)
```

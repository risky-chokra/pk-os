# Architecture

Small enough to read in an evening, layered so that each piece can be tested alone.

## 1. Layers

```
 GRUB (BIOS+UEFI, hybrid ISO, protective GPT, FAT32 ESP)
   -> kernel (host kernel by default, or scripts/build-kernel)
     -> initramfs  init/init            : find medium, mount ISO, load /mods/*.ko, switch_root
        -> live root  squashfs (ro) + tmpfs overlay(work)  : /etc is a RAM overlay
           -> /sbin/pk-boot              : parses pk_* boot options, runs /etc/pk-boot.d/S*
              -> /etc/inittab + pk-console : consoles, autologin, motd
              -> pk-* tools              : net, wifi, ssh, runtime, desktop, users, install …
```

Two optional payloads ride along in the ISO image:
`/boot/pk-runtime.sqfs` (the app runtime) and, when persistence is used, `PKPERSIST`.

## 2. Boot flow of the live system

| Stage | File | What it decides | Markers |
|---|---|---|---|
| medium probe | `init/init` | waits for `/dev/sr*`,`/dev/sd*`,`/dev/vd*`, `blkid` for label/UUID, honours `pk_media=`, `pk_iso=` (frugal ISO file), `rootdelay=` | `BOOT-OK mode=live media=…` |
| payload mount | `init/init` | loop-mount the ISO's `live/pk-rootfs.sqfs`, build `overlayfs(work=RAM)`, optional `toram` copy, `pk_verify=1` checksum of the payload | `VERIFY-OK`, `TORAM-*` |
| init handover | `init/init` | mounts `/proc /sys /dev devpts tmpfs`, then `switch_root` into the overlay | `SELFTEST-OK` |
| boot options | `rootfs/overlay/sbin/pk-boot` | turns every `pk_*=…` into env + runs hooks; `pk_run=…` at the end | `PK-BOOT-*` |
| hooks | `rootfs/overlay/etc/pk-boot.d/S*` | `S08display`, `S12users`, `S15mdev`, `S20net`, `S30ssh`, `S40persist`, `S50runtime`, `S55seatd`, `S60tune`, `S99zdisplay` | `USERS-OK`, `MDEV-OK`, `NET-OK`, `RUNTIME-OK`, `SEATD-OK`, … |
| consoles | `etc/inittab` + `sbin/pk-console` | getty on tty1-6 + `ttyS0`/`hvc0`, autologin for the live user or `pk_user=` | `USER-AUTOLOGIN (bob)` |

Hooks are POSIX `sh`, must exit 0, and are re-runnable: every one of them can be run by
hand after boot (`/etc/pk-boot.d/S55seatd start`-style), which is how they get tested
without rebooting.

## 3. Devices

* Kernel modules ship in two lists: `init/kernel-modules` (only what is needed to reach
  the root filesystem: loop, squashfs, overlay, ext4, vfat, isofs, USB/ATA/NVMe
  storage; the build expands dependencies with `modprobe --show-depends`, decompresses
  and installs them as `/mods/NN-name.ko` so load order is deterministic) and
  `config/live-modules.txt` (what the *live system* keeps on disk: GPU/KMS, network
  drivers, `sound/*`, `net/bluetooth` + `drivers/bluetooth`, `media/usb/uvc`, `hwmon`,
  `power/supply`, `video/backlight`, `thunderbolt`, `usb/typec|misc|phy`). Anything
  built into the kernel (`=y`) is skipped automatically.
* No udev, no systemd: **busybox mdev** (`etc/mdev.conf`, hook `bin/pk-devperms`) creates
  nodes and cold-plugs. `/dev` permissions are set to Debian-ish groups so ordinary
  users can work: `/dev/input/event*`→`input` 0660, `/dev/dri/card*`→`video` 0660,
  `/dev/snd/*`→`audio` 660, `/dev/ttyS*`,`/dev/ttyUSB*`→`dialout`. Driver modules load
  *after* mdev's coldplug, so nodes created late are fixed up again by `pk-devperms`
  from `S99zdisplay` (and `pk-devperms --watch` if something binds even later).
* `pk-user add` puts new users into `users,audio,input,video,render,dialout,lp`
  (+`seat` when seatd is in use) — device access comes from group membership, exactly
  like a logind system, but with a 200-line tool instead of a daemon.

## 4. Graphics and sessions

```
 S08display  : console blanking off, backlight/DRM state probe (DISPLAY-KMS / DISPLAY-TEXTONLY)
 S55seatd    : pk-seatd start  -> 'seatd -u root -g seat' inside the runtime chroot,
               so the socket lands where weston looks ($RT/run/seatd.sock)
 S99zdisplay : GPU modules already loaded -> pk-devperms, then pk-x start (if pk_desktop=1)
 pk-x        : weston --debug, LIBSEAT_BACKEND=seatd, XDG_SEAT=seat0, XDG_VTNR=<the VT that is
               actually active, read from /sys/devices/virtual/tty/tty0/active>, --tty=/dev/ttyN,
               mesa on-demand (llvmpipe when there is no accelerated GL);
               fallbacks in order: weston(KMS) -> Xorg -> Xvfb(headless) -> text only
 pk-desktop  : user-facing layer: start/stop/status/app/vnc/shot; 'shot' uses weston's own
               screencopy protocol (weston-screenshooter, wrapped in a timeout)
```

Why seatd: weston's DRM backend needs to *own* a VT and to open `/dev/dri/card0`; with
logind absent (no systemd here) it used to start fine but stay on another VT — the
compositor ran, the screen kept showing the text console. seatd (30 KB) provides the
same lease: VT + DRM + input devices, and weston logs `DESKTOP-VT (want=tty1
active=tty1 seatd=1)`. If VT ownership ever fails, the marker is
`DESKTOP-VTMISMATCH` and `pk-desktop vnc 5900` still gives you the desktop.

## 5. App runtime

`build/pk-runtime.sqfs` is produced by `scripts/make-runtime` (debootstrap `minbase` of
Debian bookworm + variant package sets + weston/wine/essentials installed through apt).
At boot `sbin/pk-runtime` finds it (inside the ISO / on a `PKRUNTIME` partition / at the
path from `pk_runtime=` / downloaded by `pk_apps_get=`), mounts it read-only at `/opt/pk`
with a writable upper (a `pk-runtime-rw.img` loopback, or `tmpfs` when the live session is
ephemeral) — the union is what makes `apt install` work without touching the base image.
`pk-shell`, `pk-get`, `pk-chroot`, `pk-run` all go through `sbin/pk-chroot`, which mounts
`/proc /sys /dev /run` bind-mounts into `/opt/pk` (they are not removed on exit because
running apps may need them; `pk-shell --clean` does). Chroot needs `CAP_SYS_CHROOT`, so
those four helpers are root-only by design; normal users use `pk-run`.

## 6. Persistence and install

* `pk-persist` carves an ext4 `PKPERSIST` partition into the free space at the end of the
  stick; with the `persistent` boot option the live overlay's work+upper directories move
  there, so `/etc` changes, added users, apt installs and files survive reboots.
* `pk-install` writes a GPT (EFI + `/boot` + root ext4 with journal), copies the squashfs
  payload (and the runtime, unless `--no-runtime-copy`), installs GRUB for the firmware it
  finds (or `--layout=bios|efi|hybrid`), creates the user with `--user=`, and drops a
  first-boot marker; `/var/log/pk-install.log` keeps the journal.

## 7. Conventions

* Every notable event prints `### PK: <NAME> (<detail>) ###` to `/dev/console` and
  `/dev/kmsg`. That is the QA protocol (`scripts/run-test.sh` greps those markers) and the
  bug-report format — do not remove a marker, add one.
* Tools must be runnable from a half-configured system: probe first, explain in the
  message, prefer `warn/info` over `fail`, exit non-zero only when something really broke.
* Live files are installed under `/bin` and `/sbin` (not `/usr/bin`), and are on `PATH`.
  Never `[ -x /usr/bin/pk-foo ]`; use `command -v` (a silent no-op bug we already hit).
* `config/live.conf` is the single place for names, versions, default command line and
  squashfs compression.

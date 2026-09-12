# Testing in an emulator before touching a USB stick

Two emulators are worth using: **QEMU** (fast, scriptable, what QA runs) and
**VirtualBox** (closest to a desktop PC: real UEFI/BIOS, VMSVGA, USB, audio).

## 1. QEMU

```sh
make run            # ISO + serial console + graphical window
make run-tty        # headless, log on the terminal
make run-efi        # UEFI instead of BIOS
```

Manual, with everything useful switched on:

```sh
qemu-system-x86_64 -machine q35 -cpu max -smp 2 -m 2048 \
  -cdrom build/pkos-apps.iso -boot d \
  -vga std -audiodev alsa,id=a0 -device intel-hda -device hda-duplex \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -monitor unix:/tmp/qm,server,nowait -serial file:/tmp/boot.log
```

* `-vga std` (Bochs/QEMU standard VGA) is the safest choice: the guest gets
  `bochs-drm`, i.e. a real KMS device, which is what weston needs.
* `-display none` makes the window disappear. The QEMU monitor's `screendump` still
  works for the text console, but with virtio-gpu it does **not** show weston's
  scanout — take `pk-desktop shot` inside the guest instead (see §2c).
* `-vga vmware` does not work: the guest kernel refuses `vmwgfx` on QEMU's limited
  SVGA emulation (`error -38`). Use `-vga std`, `-vga virtio` or `-device qxl-vga`.
* Audio: some QEMU builds have no audio backend at all. Then `-device hda-duplex`
  fails with `no default audio driver available` and the guest correctly shows
  "no soundcards" — that is a QEMU limitation, not an OS bug.

Capture a screenshot from the monitor socket (`tools/vm-shot.sh` wraps this):

```sh
tools/vm-shot.sh /tmp/qm /tmp/shot.ppm 3      # 3 frames, 2 s apart
```

## 2. VirtualBox

```sh
VBoxManage createvm --name pkos --register --ostype Linux_64
VBoxManage modifyvm  pkos --memory 2048 --vram 128 --cpus 2 --ioapic on \
                     --graphicscontroller vmsvga --firmware bios
VBoxManage storagectl pkos --name sata --controller intelahci --bus ide --add sata
VBoxManage storageattach pkos --storagectl sata --port 0 --device 0 --type dvddrive \
                     --medium /path/pkos-1.1-apps.iso
VBoxManage startvm pkos
```

`vmsvga` (or `vboxvga`) gives the guest `vmwgfx`/`vboxvideo` KMS drivers, so the
desktop session is visible on the VM screen. With `vga` (no acceleration) you still get
a working console, and `qxl` also works.

## 2b. Which display setup gives you what

| Graphics device | Driver in guest | Desktop on screen |
|---|---|---|
| VirtualBox `vmsvga` / `vboxvga` | `vmwgfx` / `vboxvideo` | yes |
| VirtualBox QEMU `qxl`, `-device qxl-vga` | `qxl` | yes |
| QEMU `-vga std`, real PCs with basic VGA | `bochs-drm` / `simpledrm`-style | yes (1280x800 in QEMU) |
| QEMU `-vga virtio` (`virtio-gpu-pci,edid=on`) | `virtio` | yes (needs an EDID, otherwise weston sees no connected output) |
| Intel iGPU | `i915` | yes |
| NVIDIA (pre-Turing, no NVK firmware) | `nouveau` | yes |
| AMD `amdgpu`, Intel `xe` | not shipped (firmware size) | text console + `pk-desktop vnc 5900` |
| QEMU `-vga vmware` | rejected by the kernel | text console only |
| headless (`-display none`) | any | session runs; capture with `pk-desktop shot` |

`pk_desktop=1` (or GRUB entry `g`, "live: desktop + apps GUI") starts the graphical
session at boot; without it the system boots to the console, which is the default.

## 2c. Desktop, seatd, users and devices — expected markers

Boot args to use for one test that covers everything:

```
pk_desktop=1 pk_tune=desktop pk_user=ravi pk_userpw=ravi pk_check=1
```

Expected lines in the serial log / `dmesg` (each is a `### PK: … ###` marker):

| Marker | Meaning |
|---|---|
| `BOOT-OK mode=live kernel=… media=/dev/sr0` | initramfs handed over correctly |
| `NET-OK (10.0.2.15)` | DHCP worked (`pk_net=dhcp`) |
| `MDEV-OK (uevent listener + coldplug, rc=0)` | device nodes + hotplug driver loading |
| `USERS-OK (users=2 groups=0 homes=0 autologin=ravi)` | users/groups/homes sanity hook |
| `USER-ADD-OK (ravi)` / `USER-AUTOLOGIN (ravi)` | the `pk_user=` boot option created the user and set the console login |
| `RUNTIME-OK src=… upper=… mode=tmpfs` | app runtime attached at `/opt/pk` |
| `SEATD-OK (socket=/run/seatd.sock in runtime, pid=…)` | session manager is up (weston's VT/DRM/input come from it) |
| `DISPLAY-KMS (drm=1 driver=bochs-drm fb=1)` | a GPU KMS device exists |
| `DESKTOP-VT (want=tty1 active=tty1 seatd=1)` | weston took the **visible** VT |
| `DESKTOP-OK (wayland-1)` | weston session is live (not the Xvfb fallback) |
| `GUI-X-OK (wayland-1)`, `GUI-APP-OK (weston-terminal)` | a real client connected and stayed up |
| `CHECK-OK (16 checks, 0 fail)` | `pk-check` found no failing row |
| `DESKTOP-XVFB (…)`, `DISPLAY-TEXTONLY`, `SEATD-SKIP (…)`, `DESKTOP-NO-RUNTIME` | informational: what is unavailable and why |
| `DESKTOP-VTMISMATCH (want=tty1 active=tty7)` | weston is running on another VT — use `pk-desktop vnc 5900` and send us the log |

Inside the guest:

```sh
pk-info                     # mode, media, mounts, IP, runtime
pk-check                    # hardware + OS self-test (display, audio, input, users…)
pk-check --users            # adds a real pk-user add -> su -> delete round-trip
pk-seatd status             # session manager state and socket
pk-user list ; pk-user add bob --admin --password=bob ; pk-user info bob
pk-user del bob --home
ls -l /dev/snd /dev/input /dev/dri     # groups: audio, input, video  (mode 0660)
pk-desktop shot /root/desktop.png      # weston's own screenshot of the desktop
pk-desktop status                       # what is running, which backend, log tails
```

`pk_run=<cmd>` is the quickest way to see something at boot without an interactive
console (spaces as `+`, multiple commands with `!`):

```
pk_run=cat+/run/pk/x-weston.log          pk_run=ls+-l+/dev/dri
```

## 3. Where the logs are

```
/run/pk/check.txt          pk-check report (rows)
/run/pk/x-weston.log       weston's own output, every attempt
/run/pk/x.log  /run/pk/desktop.log     session / launcher log
/run/pk/seatd.log  /run/pk/seatd-boot.log      session manager
/run/pk/display.txt        display state dump (also printed in motd)
/run/pk/pk_run.out         output of the pk_run= command
/run/pk/wifi-boot.log      pk_wifi= attempts
/var/log/pk-install.log (on the installed system)   installer journal
```

Send those files (or `pk-info` output) when something does not work — each marker above
maps to a fix in [TROUBLE.md](TROUBLE.md).

# First boot on real hardware

The emulator proves the OS; your machine proves the drivers. Everything below is a
5-10 minute pass. Log in as `root` (password `pk`) — or boot with
`pk_user=bob pk_userpw=bob` and use that user, which is the better test, because it
checks that an ordinary account gets its devices.

## 1. The six-line summary

```sh
pk-info                     # boot mode, medium, kernel, mounts, IP, runtime
pk-check --save --users     # /run/pk/check.txt: display, gpu, audio, input, webcam,
                            # serial, net, storage, users, seatd, desktop, kvm, uefi
pk-desktop start            # weston session (GRUB entry '4' does this at boot)
pk-desktop shot /root/desktop.png
dmesg | grep '### PK'       # every stage marker
```

## 2. Display / GPU

| Check | Expected |
|---|---|
| `dmesg \| grep '### PK: DISPLAY-KMS'` | `drm=1 driver=<yours> fb=1` |
| `ls /dev/dri` | `card0 renderD128` |
| `cat /sys/class/drm/card0/device/uevent \| grep DRIVER` | one of `i915`, `amdgpu`, `nouveau`, `radeon`, `vmwgfx`, `vboxvideo`, `qxl`, `bochs-drm`, `ast`, `mgag200`, `virtio` |
| `pk-desktop shot …` output | real desktop pixels, not a text console |

Shipped GPU drivers: Intel (`i915`), Nouveau, Radeon, VMware/VirtualBox/QEMU, qxl, AST,
Matrox, virtio-gpu, plus simpledrm/efifb fallbacks. **`amdgpu` and `xe` are not
included** (firmware size): on those machines you get a working console and
`pk-desktop vnc 5900` (llvmpipe inside the session) or you rebuild with
`amdgpu` added to `config/live-modules.txt` + the firmware package.

External/backlight: `/sys/class/backlight/*` present means `pk-tune`/`pk-x` can dim the
screen; if it is empty, brightness keys are handled by the firmware only.

## 3. Audio

```sh
ls /dev/snd                 # controlC0, pcmC0D0p, timer …
aplay -l                    # (alsa-utils, pre-installed in the apps image)
speaker-test -D plug:default -c 2 -twav -l 1
```

`snd-hda-intel`, `snd-ac97`, `snd-usb-audio` and the core modules ship in the live image;
some codecs additionally want firmware (`dmesg | grep -i 'firmware\|snd_hda'`).
In QEMU audio usually cannot be verified at all (many builds have no `-audiodev`), so
`pk-check` reports the audio row as `info`, not `fail` — real hardware is the test.

## 4. Input, serial, webcam, sensors

```sh
ls -l /dev/input/event*              # crw-rw---- root input
cat /dev/input/event0                # keys should print bytes; Ctrl-C to stop
ls -l /dev/ttyS* /dev/ttyUSB*        # dialout group
ls /dev/video*                       # webcam (uvcvideo)
ls /sys/class/hwmon/hwmon*/temp*_input
ls /sys/class/power_supply/          # batteries: BAT0/AC
ls /sys/bus/thunderbolt/devices/     # USB-C/TB, if the machine has them
```

Group membership for the current user: `id` should show `audio input video render
dialout seat`. If nodes exist but have the wrong owner/mode, run `pk-devperms`
(then `pk-devperms --watch` for drivers that bind late).

## 5. Wi-Fi / Bluetooth

```sh
rfkill list ; ip link
pk-wifi status            # interface, driver, firmware, rfkill state
pk-wifi scan
pk-wifi connect "MyAP" "secret"
bluetoothctl              # power on; scan on; (pair/trust are interactive)
```

`wpasupplicant`, `iw`, `wireless-tools`, `rfkill`, `bluez` are pre-installed in the apps
image. Cards whose firmware is non-free (most `iwlwifi`, `mt76`, `brcmfmac`) need the
firmware files: `pk-get install -y firmware-iwlwifi firmware-misc-nonfree` (or copy them
to `/lib/firmware` on the stick — see [PERSISTENCE.md](PERSISTENCE.md) for what is kept).

## 6. Users

```sh
pk-user add bob --admin --password=bob
pk-user info bob
pk-user autologin bob          # next boot: console logs in as bob
pk-user doctor                 # repairs groups/homes, checks device access
pk-user del olduser --home
```

New users are put into `users,audio,input,video,render,dialout,lp` (+`seat` when seatd
is used), which is what makes sound, the mouse/keyboard and `/dev/dri` reachable without
root. In a live session `/etc` is a RAM overlay: users vanish on reboot unless the stick
has `persistent` — or you install to disk (`pk-install --user=bob`).

## 7. Storage and speed

```sh
pk-check --speed        # read/write speed of the live medium (a slow stick is the #1
                        # "this OS is slow" report)
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,MODEL
```

## 8. If it fails: install a proper system instead of debugging the live session

```sh
pk-install --info
pk-install --target=/dev/sda --user=bob --hostname=pkstation
```
You then have the same tools plus a normal disk layout (`/home`, GRUB, ext4 with
journaling), which is the supported way to keep drivers/settings long-term.

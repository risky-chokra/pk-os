# pk's OS - the live session cheat sheet

Everything you need while the system is running. The long form lives in the source
repository under `docs/` (BUILD, VM-TEST, PENDRIVE, REAL-PC, APPS, TROUBLE,
ARCHITECTURE, PERSISTENCE, IOS-ANDROID, KERNEL, COMPARE, RELEASE).

## First five commands

```sh
pk-info                  # boot mode, live medium, kernel, mounts, IP, runtime
pk-check --save --users  # hardware + OS self-test -> /run/pk/check.txt
pk-net dhcp              # network (or boot with pk_net=dhcp)
pk-desktop start         # graphical session (weston on KMS, via seatd)
pk-help                  # the whole command list
```

## Boot options (press `e` in the GRUB menu)

```
pk_net=dhcp      pk_ssh=on        pk_keymap=in     pk_desktop=1    pk_tune=desktop
pk_user=bob pk_userpw=bob         pk_rootpw=secret pk_seatd=on    pk_check=1|gui
persistent       toram            pk_swap=auto|<MB>|off            pk_silent
pk_media=/dev/sdb  pk_iso=/path/file.iso  rootdelay=10  pk_verify=1
pk_runtime=off|auto|/dev/sda3     pk_apps_get=<pkg>:<args>
pk_install=auto|/dev/sda|ask      pk_install_user=bob pk_install_userpw=...
pk_run=<cmd>                      break=mount   single   pk_debug
```

`pk_run=` is the quickest debugging hook: spaces as `+`, separate commands with `!`
(never `;` - that is a GRUB separator). Example:
`pk_run=dmesg+|+grep+PK!ls+/dev/dri` -> output on the console and in `/run/pk/pk_run.out`.

## The ten tools that matter

| Command | Use |
|---|---|
| `pk-info` | one-page system report |
| `pk-check [--save --gui --apps --users --speed --all]` | self-test: display, GPU, audio, input, serial, webcam, net, storage, users, seatd, desktop |
| `pk-net dhcp\|status\|down`, `pk-wifi connect <ssid> <pw>`, `pk-ssh start` | network, Wi-Fi (pre-installed `wpa_supplicant`/`iw`/`rfkill`), remote shell |
| `pk-desktop start\|status\|app X\|vnc 5900\|shot f.png` | desktop session + screenshot proof |
| `pk-x start weston\|Xorg\|Xvfb`, `pk-seatd status` | the display/session layer underneath |
| `pk-user list\|add\|del\|passwd\|autologin\|doctor` | users; new users get `audio input video render dialout seat` |
| `pk-keymap in`, `pk-tune desktop\|report`, `pk-devperms` | layout, performance profile, /dev permissions |
| `pk-run <file-or-url>`, `pk-shell`, `pk-get install -y <pkg>`, `pk-chroot <cmd>` | applications through the Debian runtime at `/opt/pk` |
| `pk-runtime status\|start\|--setup <file>`, `pk-binfmt status` | where the runtime lives; foreign-arch execution |
| `pk-persist`, `pk-install` | keep changes on the stick / install to disk |

## What is already installed (no download needed)

Base live image: busybox userland + `vi`, your shell, `pk-*` tools, kernel modules for
GPU/storage/network/sound/Bluetooth/webcam/sensors.

App runtime (in `pkos-apps.iso`): `git nano vim htop tmux rsync jq zip unzip 7z tree pv
ncdu which strace lsof python3 make man` + network tools (`ip`, `dig`, `iperf3`,
`ethtool`, `socat`, `ssh`, `curl`, `wget`) + `pciutils usbutils dmidecode poppler-utils`
+ Wi-Fi/BT (`wpasupplicant iw rfkill wireless-tools bluez`) + GUI stack (`weston
xterm Xvfb mesa xwayland alsa-utils xkb-data fonts icons`) + `dillo sxiv xpdf mpg123`
+ `wine`. Verify on any boot: `dmesg | grep ESSENTIALS` ->
`### PK: ESSENTIALS-OK (count=55 missing=0) ###`.

## Files to read when something is wrong

```
/run/pk/check.txt      /run/pk/desktop.log   /run/pk/x.log
/run/pk/x-weston.log   /run/pk/seatd.log     /run/pk/runtime.log
/run/pk/wifi-boot.log  /run/pk/display.txt   /var/log/pk-net.log
dmesg | grep '### PK'  # every stage tells you what it decided
```

## iOS / Android, in one paragraph

`.ipa` files cannot run here (Mach-O + XNU syscalls + Apple code signing + closed
UIKit); `pk-ios why|info|web|mac-guest|darling` gives the details and the workable
routes (PWA, macOS guest with Xcode Simulator, Darling for macOS binaries).
`.apk` needs the Android framework: `pk-android doctor|enable|install`, then Waydroid
(with binder in your own kernel), an Android-x86 VM through `pk-vm`, or `scrcpy` to a
real phone. No version of "just run the apk" exists, and this OS will not pretend otherwise.

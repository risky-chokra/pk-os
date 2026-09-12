# Putting pk's OS on a USB stick

## 1. Which image to write

| Image | Size | Use it when |
|---|---|---|
| `build/pkos.iso` | ≈ 95 MB | you only need the live system, console, installer, network, users |
| `build/pkos-apps.iso` | ≈ 620 MB | you want the whole thing: Debian app runtime, Wine, weston desktop, essential tools |

Both are hybrid images: the same file works written to a stick, burnt to a CD, or
attached as a virtual DVD. BIOS and UEFI are both supported.

## 2. Write it

Linux / macOS:

```sh
lsblk                      # or: diskutil list   -> find the right device name!
sudo tools/write-usb.sh /dev/sdX build/pkos-apps.iso   # wipe + dd + read-back verify
# or manually:
sudo dd if=build/pkos-apps.iso of=/dev/sdX bs=8M status=progress oflag=sync
sync
sudo tools/verify-usb.sh /dev/sdX            # re-reads the stick and checks the layout
sudo tools/verify-usb.sh build/pkos-apps.iso # same checks on the ISO file
```

`tools/write-usb.sh /dev/sdX build/pkos-apps.iso --frugal` writes an alternative
layout instead: MBR + FAT32 partition with the ISO as a *file* on it, so the same
stick can carry your documents and several images. Boot that ISO with
`pk_iso=/path/to/file.iso` (the `frugal` GRUB entry does exactly that).

Windows: use Rufus (DD/raw mode) or `dd for Windows`, then
`tools/verify-usb.sh` equivalent: re-read the first bytes and compare with
`manifest.txt` (SHA-256 of the ISO).

Never write to `/dev/sda` on your own machine — `dd` does not ask twice.

## 3. Boot the target PC

1. Power on, enter the firmware menu (usually `F12`, `F2`, `Esc`, `Del`), choose USB.
2. If it does not boot: disable Secure Boot, and if the machine is old-UEFI, try
   "Legacy/CSM" instead of "UEFI".
3. At the GRUB menu you get:
   * `1` live (default, console)
   * `2` live + serial console (for log capture; add `pk_check=1` for a self-test)
   * `3` live safe (no display handling, `vga=ask`)
   * `4` live: desktop + apps (GUI)  — same as `pk_desktop=1 pk_tune=desktop`
   * `5` install to disk (asks for the target)
   Press `e` on any entry to add boot options (see README for the full list).
4. It boots into a root console. Optional: create your own user so you are not root:
   at the boot prompt add `pk_user=bob pk_userpw=bob`, or later run
   `pk-user add bob --admin --password=bob`.
5. Network: `pk-net dhcp` (or add `pk_net=dhcp` to the boot line to do it at boot).
   Wi-Fi: `pk-wifi connect <ssid> "<password>"` — `wpasupplicant`, `iw` and `rfkill`
   are already in the apps image.

## 4. What to check first (5 minutes)

```sh
pk-check --save --users --speed    # writes /run/pk/check.txt
pk-info
pk-desktop start                   # or reboot with: pk_desktop=1
pk-desktop shot /root/desktop.png  # proof the graphics session is on screen
```

Every row of `pk-check` that is not `ok` explains itself (`info`, `warn`, `fail`) and
each `fail` maps to an entry in [TROUBLE.md](TROUBLE.md).

## 5. Keep your changes on the stick (optional)

```sh
pk-persist            # uses the free space at the end of the live stick (ext4, PKPERSIST)
# or name the device explicitly: pk-persist /dev/sdX
reboot, add:          persistent            (or persistent=<label>)
```

Changes then survive reboots on that stick. This is a live-session convenience; for a
real machine use the installer (`pk-install`), which gives you an ordinary disk
installation with its own `/home`.

## 6. Install permanently instead

```sh
pk-install --info                      # shows disks + what would happen
pk-install --target=ask --user=ravi    # GPT + EFI + /boot + root ext4 + GRUB + user
```

Details and recovery: [REAL-PC.md](REAL-PC.md) §install,
[PERSISTENCE.md](PERSISTENCE.md) for what does and does not get copied.

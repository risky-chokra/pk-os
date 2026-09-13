# Putting pk's OS on a USB stick

## 1. Which image to write

| Image | Size | Use it when |
|---|---|---|
| `build/pkos.iso` | ≈ 95 MB | you only need the live system, console, installer, network, users |
| `build/pkos-apps.iso` | ≈ 648 MB | you want the whole thing: Debian app runtime, Wine, weston desktop, essential tools |

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

### If Rufus warns about the GRUB version

Rufus checks which bootloader an ISO carries and compares it with the copy it ships.
pk's OS images are built with **GRUB 2.12** (`grub-mkimage (GRUB) 2.12`), while Rufus
bundles an older GRUB, so it prints something like *"this ISO uses a newer GRUB version
than the one Rufus will install"*. That warning is not an error in the image:

* choose **DD Image mode** - Rufus copies the image byte for byte and installs no
  bootloader of its own, so the version question does not even apply;
* if you stay in ISO Image mode, Rufus rewrites the ESP with *its* GRUB and that is
  exactly what breaks the hybrid layout (no entry in the firmware boot menu);
* `tools/write-usb.sh` (Linux) and balenaEtcher always write raw, so they never show it.

You can confirm what the stick really carries:

```sh
grep -ao 'GRUB version [0-9.]*' /dev/disk/by-id/<stick> 2>/dev/null | head -1
```

A stick that boots our image reports `2.12`. Anything else means a different
bootloader was written on top of it.
## 2b. The stick does not appear in the boot menu at all

Check it before rebooting - from Linux, on the stick or on the ISO file:

```sh
tools/usb-bootable.sh /dev/sdX            # what the firmware will actually find
tools/usb-bootable.sh build/pkos-apps.iso # the image you are about to write
```

It reports the MBR signature, the partition type, the GPT header (`EFI PART`), the El Torito
catalogue and whether `/boot` (kernel, initrd, live payload) and `EFI/BOOT/BOOTX64.EFI` exist.
`VERDICT: layout looks bootable` means the image is fine and the problem is the firmware
settings below; `BAD` means the write itself was wrong.

The four causes we actually see, in order:

1. **Rufus wrote in "ISO Image mode".** Rufus then *extracts* the files and installs its own
   bootloader, which destroys the hybrid layout - the stick has no GPT and no El Torito, and
   firmware lists nothing. Re-run Rufus and when it asks **"How you want to write the image"
   choose `DD Image mode`** (if it did not ask, hold Shift and click START, or use the
   "Selection" dropdown). `balenaEtcher` or `dd for Windows` always write raw and also work.
   Wipe the stick first if the partition table is now messy: `diskpart` > `select disk N` > `clean`.
2. **Secure Boot is on.** The kernel and GRUB here are unsigned, so UEFI hides the entry
   instead of booting it. Turn Secure Boot off (some firms need a supervisor password set
   before the option becomes editable).
3. **Fast Boot / "USB boot support" is on/off.** Dell, HP and Lenovo firmware each has a
   toggle for booting from USB; Fast Boot also skips the menu key entirely. On Windows 11 the
   reliable way in: *Settings > System > Recovery > Advanced start-up > Restart now*, then
   **Use a device > UEFI: <your stick>**.
4. **The port or the stick.** USB 3 ports behind a hub and some 128 GB+ sticks behave badly at
   firmware level: use a direct USB 2.0 port, and if the BIOS has "Legacy/CSM" try that too -
   the image boots both ways.

If `tools/usb-bootable.sh` says the stick is fine but the laptop still lists nothing, write the
same image to a different stick before suspecting the PC: firmware USB init failures look exactly
like a bad image.

## 3. Boot the target PC

1. Power on, enter the firmware menu (usually `F12`, `F2`, `Esc`, `Del`), choose USB.
2. If it does not boot: disable Secure Boot, and if the machine is old-UEFI, try
   "Legacy/CSM" instead of "UEFI".
3. At the GRUB menu (English, single digit-free - press the letter in brackets):
   * `l` live (default, console)
   * `t` live: toram - copy image to RAM
   * `p` live: persistent - save changes on the stick
   * `n` live: network + SSH on
   * `g` live: desktop + apps GUI
   * `k` live: pendrive hardware self-test
   * `i` install to internal disk (asks before touching anything)
   * `a` install: headless, auto disk, then reboot
   * `d` debug: kernel log + init shell
   * `v` live: safe graphics - nomodeset   (use this if the screen stays black)
   * `b` live: safe graphics + serial 115200
   * `c` live, serial console 115200
   * `s` single user
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

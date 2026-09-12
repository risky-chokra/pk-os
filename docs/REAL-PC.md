# pk's OS · REAL-PC — emulator ke baad asli machine pe

Order jo follow kiya hai: **QEMU → live pendrive → permanent install**. Real PC pe
jaane se pehle `make test` green hona chahiye (sabse kam stage 1 + 2).

## 0. Real PC ke liye requirements

- x86_64 CPU (koi bhi 64-bit Core/Ryzen/Atom/Pentium, 2006 ke baad ka)
- **1 GB RAM** (live ke liye minimum; 2 GB comfortable — RAM overlay image ka size
  jitna hi kharch karta hai, ~41 MB base + jo change karo)
- UEFI (GPT) ya legacy BIOS, dono supported — Secure Boot **OFF** chahiye
- koi bhi disk (SATA/NVMe/USB/eMMC) 8 GB+ agar install karna ho
- USB pendrive 1 GB+ (ISO ~77 MiB hai, par poora disk wipe hota hai)

Boot-critical cheezein **initramfs me already built-in/mounted** hain: SATA/AHCI/NVMe,
USB 1.1/2.0/3.x, ext4/vfat/iso9660/udf/exfat, i8042 keyboard, USB HID, virtio-blk —
in 44 modules ke liye `init/kernel-modules` list hai, to USB pendrive/NVMe se boot
ke liye kuch aur karne ki zaroorat nahi.

NIC/Wi-Fi/GPU drivers initramfs me **jaan boojh kar nahi** (boot me net chahiye hi nahi),
par live image ke `/lib/modules` me 956 modules copy hote hain — e1000/e1000e/igb/igc,
r8169, tg3/bnxt_en, atl1c/alx, iwlwifi/ath, simpledrm, aur USB-Ethernet dongles
(r8152/ax88179/asix/lan78xx/cdc_ether). pk's OS me udev nahi hai, isliye `pk-net`
boot par inhe khud `modprobe` karta hai. Naya driver chahiye to
`config/live-modules.txt` me pattern add karke `make clean-rootfs && make iso`.

## 1. Live USB banao

```sh
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT      # USB pehchaano (e.g. /dev/sdb, 4G disk)
sudo make usb USB=/dev/sdb              # confirm maangega, dd + verify
```

`tools/write-usb.sh` kya check karta hai: device block-device hai, mounted nahi hai
(uske partitions bhi), md/lvm/crypto ka hissa nahi, root/sudo available. Ye
galatiyan real PC par sabse zyada hoti hain.

Manual (same kaam):

```sh
sudo dd if=build/pkos.iso of=/dev/sdb bs=4M status=progress oflag=sync
sync
```

> **Rufus (Windows) user:** "DD image mode" select karo — "ISO mode" filesystem
> extract karta hai aur grub.cfg kaam nahi karega.
> **balenaEtcher/Ventoy:** kaam karte hain (Etcher raw write karta hai; Ventoy ISO
> boot me grub.cfg ko grub-mkrescue image se boot karta hai — kabhi-kabhi Ventoy
> ka menu default args override kar deta hai, tab `c` dabakar check karo).

## 2. Boot

1. Reboot/reset → boot menu key: **F12** (Lenovo/Dell), **F8** (ASUS), **F9** (HP),
   **Esc** (kuch laptops), **F2** = BIOS/UEFI setup.
2. USB device select karo (UEFI mode me "UEFI: <brand>" dikhega — koi bhi chalega).
3. GRUB menu (9 entries; `e` se cmdline edit):
   - `pk's OS x.y (live)` — default, RAM overlay (reboot par sab udd jaata hai)
   - `(live: toram - image RAM me copy karo)` — media nikaal sakte ho
   - `(live: persistent - USB ke PK-PERSIST part pe save)` — changes USB par
   - `(live: network + SSH chalu)` — `pk_net=dhcp pk_ssh=on`
   - `(live: desktop + apps GUI)` — `pk_desktop=1 pk_net=dhcp` (weston → Xvfb fallback)
   - `(live: pendrive hardware check)` — `pk_check=1 pk_net=dhcp` → boot hote hi `pk-check`
     (net, USB speed, disks, DRM, KVM, SecureBoot, runtime, wine, dmesg) + report
     `/run/pk/check.txt`. `pk_check=gui` se desktop bhi test hota hai.
   - install ke saath user: `pk_install_user=ramesh pk_install_userpw=<pw>`
     (runtime bhi installed system me copy ho jaati hai → `/var/lib/pk`)
   - `(live: app runtime + network)` — `pk_runtime=auto pk_net=dhcp` (runtime ISO me
     `WITH_RUNTIME=1` se daala ho ya kisi partition par `pk-runtime.sqfs` rakho;
     apps + `pk_apps_get=<pkg>` ke liye **docs/APPS.md**)
   - `(install to internal disk)` — installer interactive (confirm maangega)
   - `(install: headless, auto disk, phir reboot)` — bina keyboard imaging
   - `(debug: kernel log + init shell)` — verbose, init me fail hone par shell
   - `(live, serial console 115200)` — serial/headless machines
   - `(single user)`
4. Kya nahi boot hua to: BIOS setup me Secure Boot OFF, "Boot mode" = `UEFI+Legacy`
   ya `Legacy only` (CSM ON).

Boot ke baad:
```
login: root
password: pk
```
tty1 par live me auto-login hai; serial console (`console=ttyS0`) par login lagta hai.
`pk-help`, `pk-info` se orientation mil jaayegi.

## 3. Hardware check (live session me)

```sh
dmesg -w | grep -iE 'error|fail|warn'      # boot ke waqt kya chhoda
pk-info                                  # mode, kernel, media, root mounts
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
ip -br a                                    # NIC dikh rahi hai?
pk-net dhcp                              # DHCP try karo
cat /proc/devices | grep -E 'block|misc' | head   # block layer
lsmod                                        # kaunse module load hue
modprobe i915                                # graphics/Wi-Fi modules try kar sakte ho
mount | grep overlay                         # root = overlay confirm
```

Awaaz/graphics/Wi-Fi firmware ke liye: `make iso PK_FIRMWARE=1` (firmware copy
karta hai, ISO badi ban jaati hai). Debian `firmware-misc-nonfree`/`firmware-linux-nonfree`
host pe install karke build karo to proprietary Wi-Fi/GPU firmware bhi mil jaayega.

## 4. Permanent install

```sh
pk-install --info                  # kaunsi disk target hogi (kuch nahi chhedta)
sudo pk-install --target=auto      # sabse badi internal disk, confirm maangega
# ya specific disk:
sudo pk-install --target=/dev/sda --root-password='NayaPass' --hostname=pk-pc
```

Layout jo banta hai (GPT):

```
/dev/sda1   2 MiB   bios_grub        (GRUB ka boot_partition, FAT nahi)
/dev/sda2   512 MiB EFI System (vfat) "PK-EFI"
/dev/sda3   baaki   ext4              label "pkos"  ← / (root)
```

- `/boot/pk-kernel`, `/boot/pk-initrd` copy — install ke baad bhi wahi initramfs
  `root=UUID=` se root dhoondhta hai (device name badal gaya to bhi boot hoga)
- `/etc/fstab` UUID-based
- `grub-install --target=i386-pc` (BIOS) **aur** `--target=x86_64-efi --removable` (UEFI,
  `EFI/BOOT/BOOTX64.EFI`) → dono firmware modes se boot ho jaata hai, NVRAM entry
  banane ki zaroorat nahi
- installed system pe `/etc/pk-installed` → pk-boot `/run/pk/require-login`
  banata hai → **autologin band, password zaroori** (security ka basic farak)
- source = pristine squashfs (`/live-base`), overlay ka junk copy nahi hota

Reboot + USB nikaalo → disk se boot. Verify:

```sh
pk-info            # mode=installed, root=<disk partition>
findmnt /             # ext4 (overlay NAHI)
touch /root/test && sync   # ab changes save honge
```

### Install ke baad kya bachta hai / nahi

| | live | installed |
|---|---|---|
| `/root`, `/etc` changes | ❌ (RAM overlay) | ✅ |
| `/tmp`, `/var/log` | tmpfs (boot pe khaali) | ext4 pe real |
| software "install" | apt nahi hai — dekhho `docs/PERSISTENCE.md` | manually copy/binary drop |
| kernel/initrd | ISO me | `/boot` me copy |

## 5. Headless / remote install (laptop ko server banao)

USB me boot args (GRUB me `e` dabakar `linux` line me add karo):

```
console=ttyS0,115200 pk_net=dhcp pk_ssh=on pk_install=/dev/sda pk_silent pk_rootpw=Passw0rd pk_halt
```

Machine: network up karega (DHCP), install karega, poweroff ho jaayega. Phir SSH:

```sh
ssh root@<ip>          # dropbear
```

`pk_install=auto` = pehli internal disk (removable skip). Confirm nahi karta — iska
matlab hai ki machine khaali hai ya data chhoda hua hai. Pehle `pk-install --info`
wale target ko live session me dekh lena behtar.

## 6. Boot na ho? (real PC troubleshooting)

| lakshan | kaaran | kya karo |
|---|---|---|
| USB boot menu me hi nahi | CSM/Legacy OFF, ya USB boot disabled | BIOS setup: `USB boot` ON, `Secure Boot` OFF, boot mode = `UEFI+Legacy` |
| GRUB tak pahunchta par "no such device" | ISO partition-style likhi gayi (Rufus ISO mode) | dobara `dd` / Etcher / `make usb` |
| `BOOT FAIL: live image ... nahi mila` | init ko `/live/pk.sqfs` nahi mila | `pk_media=/dev/sdb` try karo (GRUB me `e`); kuch USB card-readers me whole-disk vs partition ka farak padta hai |
| black screen, boot ho raha | KMS/graphics | `nomodeset` add karo, ya serial check: `console=ttyS0` se dekho kahan atka |
| keyboard dead (PS/2 ya USB) | `i8042`/`usbhid` late | `pk_media=... break=mount` shell me `insmod` check; `usbcore.legacy_hub=1` try |
| installer "internal disk nahi mili" | sab disks removable flagged, ya RAID/Intel VMD | `PK_ALLOW_REMOVABLE=1 pk-install --target=auto` ; Intel VMD/RST ko BIOS me `AHCI` karo |
| installed system boot nahi karta | GRUB NVRAM/ESP issue | live USB se boot → `pk-install --target=<disk>` dobara, ya BIOS me boot entry select karo |
| WiFi/graphics nahi chala | proprietary firmware | `make iso PK_FIRMWARE=1` + `firmware-*` packages host pe |
| bahut slow | 1 CPU core VM/TSM | real PC pe native speed — QEMU me `-accel kvm` (par sandbox me nested KVM nahi chalta) |

Extra help: [docs/TROUBLE.md](TROUBLE.md) — initramfs shell, `pk_debug`, `break=mount`,
manual mount steps, aur `dmesg` se QA markers padhna.

## I/O devices + user (real PC checklist)

Pendrive boot karke ye commands - har ek ka expected output:

```sh
pk-check                              # rows: input, audio, serial, webcam, seatd, users
ls -l /dev/snd /dev/input /dev/dri    # group/mode: audio 0660, input 0660, video 0660
pk-seatd status                       # 'RUNNING' + /opt/pk/run/seatd.sock
pk-user add ravi --admin --password=ravi ; pk-user list ; pk-user autologin ravi
pk-desktop start                      # ya GRUB entry 'g'; phir:
pk-desktop shot /root/desktop.png     # desktop ki PNG = 'aaya ya nahi' ka pixel proof
```

Expected result:
- `audio` row `[ok]` (HDA/USB sound) -> `amixer sget Master` volume bataye
- `input` row `[ok]` -> touchpad/mouse ke `event*` nodes (group `input`)
- `drm` row `[ok]` + `/dev/dri/card0` group `video` -> weston KMS par desktop
- `seatd` row `[ok]` -> normal user ko bhi session mil sakta hai
- `users` row `[ok]` -> naya user device groups ke saath; `pk-user del ravi --home` se hata diya jaata hai
- `pk-desktop shot` ki PNG me desktop (terminal window) dikhe -> **wo file bhej dena**

Koi row `[FAIL]` ya marker `DESKTOP-VTMISMATCH`/`SEATD-FAIL` ho to ye 3 logs bhejo:
`/run/pk/check.txt`, `/run/pk/x-weston.log`, `/run/pk/seatd.log` (last 10 lines each).


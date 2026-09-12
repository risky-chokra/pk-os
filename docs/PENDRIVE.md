# pk's OS · Real pendrive test sheet (ye page isolate use karne ke liye hai)

Neeche ka order follow karo — har step ka output ya to screen par dikhega ya file me
likha jaayega. Kuch fail ho to **wo file/report bhej dena**, bas.

---

## 0. Build host pe (aapke PC par)

```sh
# toolchain (ek baar) — Debian/Ubuntu
sudo apt-get install -y build-essential busybox-static cpio squashfs-tools xorriso mtools \
  grub-pc-bin grub-efi-amd64-bin grub2-common dosfstools parted e2fsprogs util-linux kmod \
  linux-image-amd64 dropbear ovmf qemu-system-x86 kbd          # kbd = console keymaps (optional)
sudo apt-get install -y debootstrap                             # App Runtime ke liye (optional)

cd pkos
make doctor            # sab OK?
make iso               # build/pkos.iso (~84 MiB)
make test              # 8 stages, ~12-20 min (QEMU) — sab green hona chahiye
make manifest          # build/manifest.txt (payload hashes)
make apps-iso          # (optional) runtime ISO ke andar: build/pkos-apps.iso
```

Reproducible payload chahiye to: `make iso REPRODUCIBLE=1` → `build/manifest.txt` ke
`/live/pk.sqfs` + `/boot/pk-initrd` hashes do baar same aayenge (ISO container ka
timestamp alag rehta hai — isliye manifest hi sahi check hai).

## 0b. Kaunsi ISO flash karein (ek hi chahiye)

**`pkos-1.0-apps.iso`** — single file kaafi hai: base OS + App Runtime (apt/Wine/GUI) dono
uske andar hain (base ke payload hashes isme bhi wahi hain; sirf `live/pk-runtime.sqfs` extra).
`pkos-1.0.iso` optional hai (84 MiB, bina runtime ke).

## 1. Pendrive pe likho

```sh
lsblk                              # device confirm karo (/dev/sdb type)
make usb USB=/dev/sdX              # tools/write-usb.sh (confirm maangega, phir dd + verify)
# ya manually:
sudo dd if=build/pkos.iso of=/dev/sdX bs=4M status=progress oflag=sync
tools/verify-usb.sh /dev/sdX build/manifest.txt      # host se verify: wahi bytes likhe?
```

`verify-usb.sh` ka result `ok=N fail=0` ho to media sahi hai. `fail>0` → dobara dd.

**dd nahi karna?** Frugal bhi chalega — FAT32 partition me `pkos-1.0.iso` file rakh do
(init loop-mount kar leta hai; pin karne ke liye `pk_iso=/pkos-1.0.iso`). Dheeme reader par
`rootdelay=40`; media mount ka error dekhna ho to `pk_fsdebug=1` (details: docs/COMPARE.md).

VM me pehle try karna ho to: **[VM-TEST.md](VM-TEST.md)** (QEMU/VirtualBox/VMware settings + expected markers).

## 2. PC se boot

0. **Kya dikhega (normal)**: 0-15 s GRUB menu -> ~15-25 s **poori kaali screen** (kernel/GPU handoff - ye expected hai, boot atka hua nahi) -> ~25 s me `### PK: BOOT-OK ###`, motd aur `login: root / password: pk`. **60 s tak ruko**; uske baad bhi kaali rahe to menu me `v` (safe graphics / nomodeset) chuno, ya `docs/VM-TEST.md` ka "GRUB ke baad screen kaali" section (usme VirtualBox headless + `controlvm screenshotpng` ka tareeqa bhi hai).
1. BIOS/UEFI setup me: **Secure Boot OFF** (hamara GRUB unsigned hai), boot menu se USB select.
2. GRUB menu (hotkeys):

| key | entry | kya karta hai |
|---|---|---|
| `l` | live | normal live session (login: root / `pk`) |
| `g` | desktop + apps | `pk_desktop=1 pk_net=dhcp` → weston/Xvfb session + terminal |
| `k` | **pendrive hardware check** | `pk_check=1 pk_net=dhcp` → boot hote hi `pk-check` chala ke report banata hai |
| `n` | network + SSH | `pk_net=dhcp pk_ssh=on` (dropbear :22) |
| `p` | persistent | changes USB ke PK-PERSIST partition pe save |
| `i` | install to disk | `pk_install=ask` (confirm ke saath) |
| `a` | headless install | `pk_install=auto pk_silent pk_halt` |
| `d` | debug | kernel logs + init shell |
| `c` | serial console | `console=ttyS0,115200n8` |
| `s` | single user | |

Kisi bhi entry par `e` dabakar options add kar sakte ho, jaise:

```
pk_keymap=in  pk_rootpw=MyPw  pk_install_user=ramesh pk_install_userpw=SomePw
pk_runtime=/dev/sdb3  pk_apps_get=htop  pk_check=gui  pk_desktop=1  persistent
pk_wifi=<ssid>:<password>      # laptop jisme ethernet nahi (experimental: wpa_supplicant
pk_swap=<MB>|auto                      # swapfile (installed: /var/tmp, live+persist: /persistence); live me guard se skip
                               #  runtime me chahiye -> pk-get install -y wpasupplicant iw)
```

## 3. Live session me ye 6 commands

```sh
pk-check --save            # POORA report (net, USB speed, disk, display, KVM, SecureBoot...)
less /run/pk/check.txt     # (ya /tmp/pk-check.txt)
pk-info                    # boot mode, media, modules, runtime ka haal
pk-run --list              # apps layer: runtime laga hai? kitne packages? wine/java/weston?
pk-run --selftest          # app dispatch battery (ELF/script/.deb/.exe/AppImage/jar/rpm/iOS/Android)
dmesg | grep PK            # boot markers (neeche dekho)
```

Pass ka matlab (serial/console par ye lines aani chahiye):

```
### PK: BOOT-OK mode=live ...
### PK: MDEV-OK (uevent listener + coldplug, rc=0) ###   # plug & play driver loading
### PK: VERIFY-OK (pk.sqfs) ###                 # payload integrity (pk_verify=1 wale boot par)
### PK: TUNE-REPORT-OK ###  BINFMT-STATUS-OK  ARCH-DISPATCH-OK
### PK: DEPS-OK ###
### PK: NET-OK (192.168.x.x) ###          # agar pk_net=dhcp diya
### PK: RUNTIME-OK src=... mode=rw-image ...   # runtime laga ho
### PK: APPS-OK ###                       # app battery poori pass
### PK: CHECK-OK (N checks) ###           # pk-check me ek bhi FAIL nahi
### PK: CHECK-SUMMARY ok=N fail=0 warn=M info=K ###
### PK: DESKTOP-OK (:1) ###  GUI-X-OK  GUI-XCLIENT-OK  GUI-APP-OK   # pk_desktop=1/pk_check=gui ho to
```

`CHECK-FAIL(n)` dikhe to report ki us line me reason hota hai (jha `warn` normal hai:
jaise Wi-Fi firmware nahi, ya /dev/kvm nahi).

## 4. App test (pendrive pe hi)

```sh
# Linux app (.deb) — runtime chahiye (apps ISO ya PK-RUNTIME partition)
pk-get install -y htop                     # net ke saath; lists image me hain to fast
pk-run --install ./some-app.deb            # dpkg ho to wahi, warna extract + launcher
pk-run ./binary ./script.sh ./AppImage-file ./app.deb ./Setup.exe ./app.jar
pk-run --info ./unknown-file               # type kya hai
pk-run --gui xterm                         # desktop session ke saath
pk-desktop app htop                        # ya
pk-run --uninstall htop                    # hatao

# Windows
pk-get install -y wine                     # ya apps/desktop ISO me pehle se
pk-run ./Setup.exe ; pk-run ./installer.msi  # msiexec /i se
wine --version                               # (runtime ke andar) pk-run wine --version

# iOS / Android (sach + raaste)
pk-ios why ; pk-ios info ./app.ipa ; pk-ios web https://icloud.com ; pk-ios mac-guest
pk-android doctor ; pk-android kernel-frag
```

Reboot test (persistence): `pk-run --install` se koi app install karo, `reboot`, phir
`pk-run --list` me wo dikhe to overlay persistence sahi hai (apps ISO me `mode=tmpfs`
aayega kyunki ISO read-only hai — persistence ke liye `persistent`, ya PK-RUNTIME
partition, ya installed system chahiye).

## 5. Permanent install (internal disk)

```sh
pk-install --info                     # kaunsi disk target hogi (kuch nahi chheda)
pk-install --target=auto --user=ramesh --user-password=SomePw     # interactive confirm
# boot option se headless:
#   pk_install=auto pk_install_user=ramesh pk_install_userpw=SomePw pk_rootpw=... pk_silent pk_halt
```

Install ke saath ye bhi hota hai (naya):
- app runtime installed system me copy ho jaati hai → `/var/lib/pk/pk-runtime.sqfs`
- `/var/lib/pk/pk-runtime-rw.img` ban jaati hai → **installed apps reboot ke baad bhi**
- non-root user (uid 1000/1001, `/home/<user>`, sudo/users group me)

Uske baad USB nikaal do: disk ka apna GRUB boot karega, login maangega
(`root` + root password, ya `ramesh` + user password), aur
`dmesg | grep PK` me `RUNTIME-OK ... mode=rw-image (/var/lib/pk/pk-runtime-rw.img)`
dikhega (ye QA stage 8 me automate hai ✓).

## 6. Agar kuch na chale

| lakshan | pehla kaam |
|---|---|
| USB boot list me hi nahi | BIOS me Secure Boot OFF, "USB legacy/UEFI" dono try; `tools/verify-usb.sh /dev/sdX` |
| GRUB aata hai par kernel panic | `make iso` host ke `/boot/vmlinuz-*` + `/lib/modules` use karta hai → `PK_KERNEL=`/`PK_MODULES=` se doosra kernel; `dmesg` me ` squashfs` error ho to `make iso SQUASH_COMP=xz` (kernel me zstd na ho) |
| Black screen, koi prompt | `c` (serial) try, ya `pk_debug`; display na ho to `g` ki jagah `l` |
| Net nahi (wired) | `pk-net dhcp` ; marker `NET-OK (ip)` dekho. `udhcpc rc=0` par IP na aaye → `default.script` ka exec bit (purani ISOs): `ls -l /usr/share/udhcpc/default.script` (755 chahiye); fixed in current build |
| Wi-Fi connect karna hai | `pk-wifi status` → phir `pk-get install -y wpasupplicant iw` (runtime me) → `pk-wifi connect <ssid> <pw>`. Boot me hi chahiye to `pk_wifi=<ssid>:<pw>`. Ye path **is sandbox me test nahi hua** (wireless hardware nahi) — fail ho to `/run/pk/wifi-boot.log` bhejo |
| Naya user chahiye (apna account) | `pk-user add bob --admin --password=...` -> groups: audio,input,video,render,seat (device access). `pk-user autologin bob` se boot me uska shell; `pk-user list`, `pk-user doctor`. **Live ISO me /etc RAM me hai** -> reboot par user tabhi bachega jab `persistent` boot option ya installed system ho |
| Screen par desktop (weston) | apps ISO + GRUB entry 5 (`g`). weston ko VT chahiye -> hamara **seatd** (`S55seatd` hook / `pk-seatd start`) use karta hai; marker: `PK: SEATD-OK`, `PK: DESKTOP-VT (want=tty1 active=tty1)` |
| Audio/gamepad/serial/webcam chahiye | live me `snd-hda-intel`, `snd-usb-audio`, `snd-ac97`, bluetooth, uvc(webcam), hwmon, battery, typec modules ship hote hain + `/etc/mdev.conf` se `/dev/snd`(audio), `/dev/input`(input), `/dev/dri/card*`(video) groups ke saath; test: `pk-check` (rows: audio/input/serial/seatd) |
| App not found / permission | `pk-info`, `pk-run --list`, `pk-runtime status`; runtime ke liye `sudo make runtime` + `make apps-iso` |
| Install ke baad boot nahi | BIOS me us disk ko first boot karo; `pk-install` ke log me `grub-install` ki line dekho (`pk_silent` ho to /run/pk-install.log tail console par aata hai) |

**Mujhe bhejo:** `/run/pk/check.txt` (ya `/tmp/pk-check.txt`), `dmesg | grep PK` ka
output, aur `make manifest` ka `build/manifest.txt` — teeno text hain, koi screenshot nahi.

## 7. Jaan-boojh ke nahi kiya gaya (limits)

- **Secure Boot signing** nahi (unsigned GRUB) → BIOS me OFF karna padega.
- **Wi-Fi connect** (`wpa_supplicant`) image me nahi — sirf `pk-check`/`pk-get` se install.
- **LUKS encrypted install** nahi (initramfs me cryptsetup chahiye, alag round ka kaam).
- **iOS apps native nahi** chalti (Mach-O + closed UIKit) → `pk-ios why` dekho; macOS guest
  + Xcode Simulator hi asli raasta hai; `pk-vm` helper hai par guest ab tak is sandbox me
  boot karke nahi test hua.
- **Android**: `pk-android doctor` jo blocker dikhata hai (binderfs) wahi sacche me
  blocker hai; apne kernel ke bina `.apk` native nahi chalegi.
- Pendrive pe boot karke **GUI + Wine se asli Windows app** chalana abhi QEMU me hi
  prove hua hai (Xvfb round-trip ✓); terahz GPU/KMS par test aapke PC par hi hoga.

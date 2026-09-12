# pk's OS

> Repo: **https://github.com/risky-chokra/pkos** · Release (base ISO + manifests + git
> bundle): **https://github.com/risky-chokra/pkos/releases/tag/v1.0.0** · Status: [STATUS.md](STATUS.md)

Apna khud ka chhota Linux OS — **x86_64 PC / laptop pe live USB se boot hota hai**, aur
chahe to **permanent install** bhi ho jaata hai. Koi existing distro ka installer nahi,
sab kuch is repo se build hota hai: kernel (host ka ya apna), busybox, squashfs, initramfs,
GRUB, installer — sab scripts me.

```
 build/pkos.iso  ──dd──►  USB pendrive  ──boot──►  Live session (RAM overlay)
                                     │
                                     └─► pk-install --target=auto  ──►  permanent install
```

| | |
|---|---|
| Image | squashfs (zstd) + overlayfs, root = read-only base + RAM upper |
| Init | custom initramfs `/init` (busybox ash) → `run-init` → busybox init |
| Kernel | host ka `/boot/vmlinuz-*` (default) **ya** `make kernel` se apna |
| Boot | hybrid ISO: BIOS (i386-pc) + UEFI (x86_64-efi), `dd` se USB pe |
| Install | `pk-install` → GPT (bios_grub + ESP + ext4) + GRUB + `root=UUID=` |
| Size | **77 MiB ISO** (80.9 MB) = 41 MiB squashfs rootfs (956 kernel modules, NIC drivers included) + 3.3 MiB initramfs (44 boot modules) + kernel |
| Login | live: `root` / `pk` (auto-login) · installed: password zaroori |

---

## 1. Quick start (Debian / Ubuntu host)

```sh
# toolchain (ek baar)
sudo apt-get update
sudo apt-get install -y build-essential make busybox-static cpio squashfs-tools \
    xorriso mtools dosfstools parted e2fsprogs util-linux kmod \
    grub-pc-bin grub-efi-amd64-bin grub2-common initramfs-tools-core \
    linux-image-amd64 dropbear openssl
# emulator QA ke liye (recommended)
sudo apt-get install -y qemu-system-x86 ovmf

git clone <repo> pkos && cd pkos
make doctor        # sab tools hai? version check
make iso           # -> build/pkos.iso   (~1-2 min)
make test          # emulator me 8-stage QA (live · install · installed-boot · toram ·
                   #   UEFI · persistence+net+ssh · app runtime · pendrive kit)  ~15 min
make check         # sirf stage 8 (pk-check + keymap + install user/runtime copy)
make gui-test      # stage 8 + desktop session (weston/Xvfb + xterm round-trip)
make apps-iso      # base ISO + App Runtime andar -> build/pkos-apps.iso
make manifest      # build/manifest.txt (payload hashes) ; make verify = uska check
make bundle        # git bundle + source tar (sandbox/PC transfer ke liye)
make run           # QEMU me live session (serial/stdio)
```

`make test` ka output aisa dikhega (har stage ka poora serial log `build/test-logs/` me):

```
=== 0/7  test ISO variant (default args: selftest + poweroff + ttyS0) ===
  PASS test ISO: pkos-test.iso (78M)
=== 1/7  live boot from ISO (grub + cdrom) ===
  PASS grub -> kernel -> initrd -> squashfs + overlay -> init
  PASS self test pass (RAM overlay writable)
  PASS squashfs base read-only hai
  PASS installer ke tools (parted/mke2fs/grub-install...) chal sakte hain
=== 2/7  headless install -> testdisk.img (3072MB virtio disk) ===
  PASS installer pura hua (partition + copy + grub)
  PASS installed tree sahi (init + kernel + initrd + marker)
  PASS root password install ke baad 'PkTest-123' se match karta hai (sha-5)
  PASS installed grub.cfg root=UUID use karta hai (device-name pe depend nahi)
  PASS installed system me DHCP on hai (etc/default/pk)
=== 3/7  installed disk ka apna GRUB (BIOS) -> installed root ===
  PASS installed system boot hua (apne GRUB se)
  PASS installed /etc/shadow me real sha-crypt hash hai
  PASS installed system password maangta hai (autologin nahi)
=== 4/7  toram (image RAM me copy -> media mount reuse) ===
  PASS image RAM me copy hua
  PASS toram ke baad bhi system boot hua
=== 5/7  UEFI (OVMF) boot from ISO ===
  PASS UEFI (OVMF) se bhi boot hota hai
=== 6/7  persistence (PK-PERSIST disk) + DHCP + SSH ===
  PASS init ko persistence partition mili
  PASS root overlay ka upperdir persist disk par hai
  PASS reboot ke baad bhi changes zinda (persistence kaam karta hai)
  PASS DHCP se IP mila (pk_net=dhcp)
  PASS dropbear SSH chalu (pk_ssh=on)
=== 7/7  app runtime (Linux/Windows/.deb dispatch) + pk-run selftest ===
  PASS app runtime /opt/pk par attach hua (PK-RUNTIME disk se)
  PASS native Linux ELF app chali
  PASS .deb install + launcher bana
  PASS Windows .exe Wine dispatch se chala
  PASS .apk pehchana + honest diagnostic (binder/waydroid)
  PASS Mach-O (macOS) sahi reason ke saath mana kiya
  PASS installed app runtime ke rw overlay me hai (host se verify)
  PASS dusri boot par bhi runtime attach hua

==================================================
  QA PASS  43 checks ok  (logs: build/test-logs)
```
(43 = saate stages ke total checks; machine pe depend karta hai — TCG emulation me
~10 min lagte hain. `make test-apps` se sirf apps layer, ~30 s me.)

## 1b. Do ISO kyun — aur kaunsi **ek** file lein

Chahiye to sirf **ek**: `pkos-1.0-apps.iso` (700 MiB). Wo superset hai — andar bilkul wahi
base OS hai (`boot/pk-kernel`, `boot/pk-initrd`, `live/pk.sqfs` ke sha256 dono ISO me **same**,
manifest se verify kiya) + upar se ek extra file `/live/pk-runtime.sqfs` (Debian App Runtime:
apt/dpkg + Wine + weston/Xvfb + xterm). `pkos-1.0.iso` (84 MiB) optional hai — "bas boot +
install + tools" chahiye ya net slow hai to.

| file | andar kya | kab lo |
|---|---|---|
| `pkos-1.0-apps.iso` | base OS **+** `/live/pk-runtime.sqfs` (apt, Wine, weston, xterm, mesa) | **recommended — ek hi file flash karo** |
| `pkos-1.0.iso` | base OS only (koi runtime nahi) | chhota download; apps baad me `sudo make runtime` se |

Runtime ko jaan-boojh ke alag layer rakha hai, kyunki wo 3 jagah se aa sakta hai — ISO ke
andar, USB ke alag `PK-RUNTIME` partition me, ya installed system ke `/var/lib/pk` me
(design: docs/APPS.md). Isi liye base image chhota rehta hai aur apps layer add-on hai.

## 2. Live pendrive banao
### 2a. Frugal boot (bina dd ke) + media retry

`pkos*.iso` file ko kisi bhi partition (FAT32/exFAT/NTFS/ext4) par rakh do — init use
loop-mount karke `/live/pk.sqfs` nikaal leta hai (Ubuntu `iso-scan`/TinyCore/Alpine jaisa):

```sh
# stick par: (MBR + ek FAT32 partition) aur usme pkos-1.0.iso file
sudo mkfs.vfat -F 32 /dev/sdX1 && sudo mcopy -i /dev/sdX1 build/pkos.iso ::/pkos-1.0.iso
# boot option se pin karo (auto-scan bhi karta hai):  pk_iso=/pkos-1.0.iso
# dheeme USB reader ke liye:  rootdelay=40      (default 12 s wait hota hai)
# media mount debug:         pk_fsdebug=1       (har mount ka asli error + size + head bytes)
```



```sh
lsblk                                  # USB ka naam dekho (jaise /dev/sdb)
make usb USB=/dev/sdb                  # confirm maangega, dd + verify karega
```

`make usb` = `tools/write-usb.sh`, jo mounted-disks/system-disk jaisi galtiyan hone se
rokta hai. Manually:

```sh
sudo dd if=build/pkos.iso of=/dev/sdb bs=4M status=progress oflag=sync
```

> Windows pe: **Rufus → "DD mode"** (ISO mode nahi), ya `dd`/`usbimager`.

Booting: reset → boot menu (`F12` / `F8` / `Esc` / `F2`) → USB select karo.
**Secure Boot OFF karo** — pk's OS self-built hai, signed nahi.
GRUB menu me 9 options (hotkey bracket me): `live` [l], `toram` [t],
`persistent` [p], `network + SSH` [n], `install to internal disk` [i],
`install: headless` [a], `debug` [d], `serial console` [c], `single user` [s],
`desktop + apps` [g], `pendrive hardware check` [k].
`e` dabakar kisi bhi entry me kernel cmdline edit bhi kar sakte ho.

Live session me:

```
login: root        password: pk          # (autologin on tty1; serial pe login)
pk-help         # sab commands
pk-info         # mode/kernel/media/root mount
pk-net dhcp     # network
pk-ssh          # dropbear SSH server
pk-persist      # USB pe persistence partition banao (changes save hoonge)
pk-check --save # HARDWARE + OS self-test (net, USB speed, disks, DRM, KVM, SecureBoot,
                # runtime, wine, dmesg...) -> report /run/pk/check.txt
pk-desktop      # GUI session (weston -> Xvfb fallback) + terminal ; pk-desktop app htop
pk-run ./app    # koi bhi app: ELF, script, .deb, AppImage, .jar, .exe/.msi (Wine), .ipa
pk-run --selftest        # app dispatch battery (### PK: APPS-OK ###)
pk-run --sandbox ./app   # app ko namespaces me (user/pid/mnt/net) + /root /home chhupe
pk-tune report           # CPU governor+EPP, sched, IO scheduler, IPC, security, TPM (read-only)
pk-tune desktop          # desktop profile: cgroups (apps 200/bg 20), mq-deadline, BBR/fq, THP
pk-tune hybrid           # P/E core detect -> daemons efficiency cores par (cpu_capacity se)
pk-binfmt register       # arm64/arm/riscv64/ppc64le ELF -> qemu-user se direct (runtime me qemu-user-static)
pk-desktop outputs       # connected displays + modes ; pk-desktop scale 2 [OUT] (HiDPI, no reboot)
pk-ios why               # iOS apps ka sach + raaste (web wrapper / macOS guest / Darling)
pk-android doctor        # .apk ke liye kya missing hai (binderfs/waydroid)
pk-keymap in             # keyboard layout (console + GUI)
pk-wifi status           # Wi-Fi ka haal (connect: pk-wifi connect <ssid> <pw>)
pk-install --target=auto # permanent install (confirm maangega)
```

## 3. Permanent install

Live USB se boot karke:

```sh
pk-install --info                 # kaunsi disk milegi, kuch nahi chhedta
pk-install --target=auto --yes    # pehli internal disk pe GPT + ext4 + GRUB
```

Kya-kya hota hai:
- GPT: `p1` bios_grub (2 MiB) · `p2` ESP vfat (512 MiB) · `p3` ext4 root (baaki space)
- Root filesystem **squashfs se copy** hoti hai (RAM overlay ka kachra nahi jaata)
- `/boot/pk-kernel` + `/boot/pk-initrd` copy — wahi initramfs `root=UUID=` resolve karta hai
- `/etc/fstab` UUID se, `grub-install` **i386-pc aur x86_64-efi dono** (hybrid boot)
- Installed system pe `/etc/pk-installed` hota hai → **login password maangta hai**
  (live ka default `pk`, `--root-password=` se badlo)

Reboot karke USB nikaal lo → disk se boot.

### Headless / unattended install (koi keyboard nahi)

GRUB menu se `install (headless auto)` chuno, ya kernel cmdline:

```
pk_media=/dev/sdb pk_install=auto pk_silent pk_halt pk_rootpw=MeraPass
```

- `pk_install=auto|<dev>` → boot hote hi install
- `pk_silent` → installer ka output `/run/pk-install.log` me, console par tail
- `pk_halt` → khatam hote hi `poweroff` (imaging ke liye)
- `pk_net=dhcp` → boot par NIC driver load karke DHCP (udev nahi hai, isliye
  `pk-net` khud `modprobe` karta hai: virtio_net, e1000/e1000e, igb/igc, r8169,
  tg3/bnxt_en, atl1c/alx + USB-Ethernet (r8152, ax88179, asix, lan78xx, cdc_ether, smsc75xx))
- `pk_ssh=on` → dropbear :22 chalu (`root`/`pk` se login; `pk_ssh=off` se band)
- `pk_install_user=ramesh pk_install_userpw=<pw>` → install ke saath non-root user bhi
  (home dir + sudo/users group); `pk_rootpw=` root ka password
- `pk_check=1` → install ke baad bhi `pk-check` ki report (`/run/pk/check.txt`) disk par
  copy karne ki zaroorat nahi padti; live me hi sab record ho jaata hai
- `pk_wifi=<ssid>:<pw>` → Wi-Fi se connect (experimental, runtime me wpasupplicant)
- `pk_verify=1|require` → boot par `/live/pk.sqfs` ka sha256 sidecar se verify (payload integrity)
- `pk_tune=report|desktop|hybrid` → S60tune hook (CPU/IO/IPC/cgroup tuning; `PK_TUNE=` se default)
- `pk_swap=<MB>|auto|off` → boot par swapfile (auto = RAM/2, 1–8 GB clamp). Live ke tmpfs/overlay
  root par ye **jaanboojh ke** skip hota hai (warna swap = RAM khana); installed system ya
  PK-PERSIST (ext4) par `/persistence/pk-swapfile` (live me persist mount yahi hai) ban ke `swapon`
  ho jaata hai. Marker:
  `### PK: TUNE-SWAP-OK (NM) ###` / `TUNE-SWAP-SKIP`. Manual: `pk-tune swap 2048` (MB), `pk-tune swap 0` (off).
  (Zyadatar logon ke liye ye **on karne ki zarurat nahi** - live session me skip hi sahi behavior hai.)
  `PK_SWAP=` se /etc/default/pk me default.
- `pk_mdev=off` → busybox mdev hotplug hook band (default on: plug-and-play modprobe)
- Baad me bhi: `pk-net dhcp` / `pk-net status` / `pk-ssh start`

Installed system me `pk-install` `/etc/default/pk` ka `PK_DHCP=yes` kar deta
hai — reboot par network apne aap up (QA stage 2 me yeh bhi check hota hai).

## 4. Apna kernel (optional, par mazedar)

```sh
make kernel                                   # download + build (~30-90 min, 2 core pe)
make clean-rootfs
make iso PK_KERNEL=$PWD/build/kernel-6.12/bzImage \
          PK_MODULES=$PWD/build/kernel-6.12/lib/modules/6.12.0
```

`scripts/build-kernel` defconfig pe boot-critical cheezein built-in karta hai
(`BLK_DEV_LOOP`, `SQUASHFS`, `OVERLAY_FS`, `EXT4`, `ISO9660`, `VFAT`, `VT`, `SERIAL_8250_CONSOLE`)
aur baki hardware module me — initramfs me sirf wahi jaate hain jo chahiye.
Config philosophy aur knobs: [docs/KERNEL.md](docs/KERNEL.md).

## 5. Repo ka layout

```
Makefile                 sab targets (doctor/live/squash/initrd/iso/run/test/usb/kernel/clean)
config/live.conf         naam, version, hostname, live password, squash compression, cmdline
config/live-bins.txt     live image me jaane wale host binaries (parted, mke2fs, grub-*, dropbear…)
config/live-modules.txt  live /lib/modules me jaane wale module patterns
init/init                initramfs ka /init  (media dhoondho → squashfs+overlay → run-init)
init/kernel-modules     initrd me jaane wale modules (boot-critical)
init/grub.cfg            ISO ka GRUB menu template (13 menuentries + hotkeys)
scripts/build-rootfs     squashfs ke liye tree stage karta hai
scripts/collect-bins     ELF + ldd closure → rootfs me absolute paths ke saath
scripts/mk-squashfs      mksquashfs (zstd, 1 MiB blocks, -all-root)
scripts/mk-initrd        /init + modules + busybox → gzip cpio
scripts/mk-iso           grub-mkrescue → hybrid ISO
scripts/run-qemu.sh      QEMU launcher (BIOS/UEFI/serial/kernel-boot, sandbox-friendly)
scripts/run-test.sh      6-stage emulator QA (live → install → installed boot → toram → UEFI → persistence+net+ssh)
scripts/doctor.sh        toolchain check
rootfs/overlay/          OS ke config + scripts (pk-boot, pk-install, inittab, …)
tools/write-usb.sh       dd to USB, safety checks ke saath
tools/verify-usb.sh      pendrive/ISO ka content manifest se verify (rebuild check)
tools/restore-from-iso.sh workspace/git reset me rootfs/overlay udd jaaye to ISO se restore
scripts/manifest.sh      ISO ke payload files ke sha256 (build/manifest.txt)
tools/gen-shadow-hash    sha-512 root hash banao (etc/shadow ke liye)
docs/                    BUILD · PENDRIVE · REAL-PC · PERSISTENCE · APPS · IOS-ANDROID · KERNEL · TROUBLE
```

Aur details:
[docs/BUILD.md](docs/BUILD.md) · [docs/REAL-PC.md](docs/REAL-PC.md) ·
[docs/PERSISTENCE.md](docs/PERSISTENCE.md) · [docs/TROUBLE.md](docs/TROUBLE.md) ·
[docs/APPS.md](docs/APPS.md)

## 5b. Apps chalana (Linux / Windows / Android / macOS)

Base ISO chhota hai isliye usme sirf busybox + drivers hain. **App Runtime** jodte ho to
koi bhi Linux app chalne lagti hai (aur Wine se Windows wali):

```sh
sudo make runtime                 # build/pk-runtime.sqfs (Debian minbase, ~37 MiB)
make iso WITH_RUNTIME=1           # runtime ISO ke andar -> /opt/pk boot par apne aap
```

Boot par (ya `pk-runtime start` se) runtime `/opt/pk` par overlay ke saath lag jaata hai:

```sh
pk-get install -y htop vim wine    # koi bhi Debian package (net: pk_net=dhcp)
pk-run ./binary ./script.sh ./app.deb ./Setup.exe ./AppImage ./app.jar
pk-run --info ./file              # type batao (elf / deb / dos-exec / apk / mach-o …)
pk-run --selftest                 # QA battery: ### PK: APPS-OK ###
pk-shell                          # runtime ke andar shell        pk-x start weston (GUI)
```

| app | kya hota hai |
|---|---|
| Linux ELF / script / `.deb` / `.rpm` / AppImage / `.jar` | ✅ chalti hai (`.deb` me dpkg ho to wahi, warna in-house `ar`+tar extract + launcher) |
| Windows `.exe` / `.msi` | ✅ **Wine se** (`pk-get install -y wine`); Wine na ho to `pk-run` exact command bataake rc 72 deta hai |
| Android `.apk` | ❌ direct nahi — Android runtime (binderfs + apna kernel) chahiye; `pk-run` **Waydroid** ka raasta batata hai |
| macOS `.app` / `.dmg` / Mach-O | ❌ Linux kernel Mach-O ko execute nahi kar sakta (Darwin chahiye) → `pk-vm` se macOS guest; `pk-run` saaf reason deta hai |

Poora doc (runtime kaise banane/kahaan rakhane kare, persistence, GUI, `pk_apps_get=`, QA
modes, troubleshooting): **[docs/APPS.md](docs/APPS.md)**

### 5d. Real pendrive test ka short version

```sh
sudo dd if=build/pkos.iso of=/dev/sdX bs=4M status=progress oflag=sync
tools/verify-usb.sh /dev/sdX build/manifest.txt     # host se: wahi bytes likhe?
# PC pe: Secure Boot OFF, USB se boot -> menu me 'k' (hardware check)
pk-check --save      # net/USB speed/disk/DRM/KVM/SecureBoot/runtime/wine/dmesg
pk-run --selftest    # app dispatch battery
pk-desktop           # GUI (weston -> Xvfb fallback)
```
Poora sheet + fail par kya bhejna hai: **[docs/PENDRIVE.md](docs/PENDRIVE.md)**

### 5c. Pendrive/real-PC kit (live system ke andar)

```sh
pk-check --save      # hardware + OS self-test: net, USB speed, disks, DRM/KMS, SecureBoot,
                     # runtime, wine, dmesg errors... report: /run/pk/check.txt
pk-check --gui       # desktop bhi utha ke X-client round-trip check
pk-desktop           # weston (KMS) -> Xorg -> Xvfb fallback, + xterm welcome
pk-desktop app htop  # koi GUI app session me kholo
pk-keymap in         # console (loadkmap) + GUI (setxkbmap) layout
pk-ios why|info file.ipa|web <url>|mac-guest|darling   # iOS ki sachchai + 3 raaste
pk-android doctor|enable|install x.apk|kernel-frag      # Android (binderfs) ka haal
```

Boot options (GRUB me `e`, ya menu entries `g`/`k`): `pk_check=1` (ya `pk_check=gui`),
`pk_run=<cmd>` (boot ke baad ek command ka output console par — debug ke liye; space `+`, commands `!` se alag)
`pk_desktop=1`, `pk_keymap=<layout>`, `pk_install_user=<name> pk_install_userpw=<pw>`.

| doc | kis liye |
|---|---|
| [docs/PENDRIVE.md](docs/PENDRIVE.md) | **aapke real pendrive test ka sheet** (kya karna hai, kaunsi line pass mani jaayegi, kya bhejna hai) |
| [docs/VM-TEST.md](docs/VM-TEST.md) | **VirtualBox / VMware / QEMU me chalane ka sheet** (settings, commands, expected `### PK:` markers, atakne par fix) |
| [docs/IOS-ANDROID.md](docs/IOS-ANDROID.md) | iOS/Android: kya chalta hai, kyun nahi chalta, kaunse raaste actually kaam karte hain |
| [docs/COMPARE.md](docs/COMPARE.md) | Alpine / ArchISO / Fedora-live / Ubuntu-casper / TinyCore / SystemRescue / Ventoy se **live-boot matric** ka tulna — kya seekha, kya add kiya, kya jaan-boojh ke nahi kiya |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | modern desktop-OS requirements (scheduling/GPU/memory/security/IPC) — is OS me kaun karta hai, kaise verify karein, kya possible nahi |
| [docs/APPS.md](docs/APPS.md) | App Runtime (Debian userland + apt + Wine) |
| [docs/TROUBLE.md](docs/TROUBLE.md) | markers se debugging |

## 6. Kaise kaam karta hai (2 min ka tour)

1. **GRUB** (ISO ke andar) `linux /boot/pk-kernel` + `initrd /boot/pk-initrd` load karta hai.
2. **/init** (initramfs) `devtmpfs/proc/sys` mount karta hai, `/mods` se loop+squashfs+overlay+ext4+iso9660
   load karta hai, phir **har disk + partition** ko try karta hai — jispe `/live/pk.sqfs` mile wahi
   boot media hai (`/dev/sdb` poora-disk hota hai jab ISO `dd` ki ho, isliye partition nahi disk bhi try hota hai).
3. squashfs **read-only** mount (`/ro`) + **overlayfs** (`upper` = tmpfs, ya `PK-PERSIST` partition)
   → `run-init` se `/newroot/sbin/init` (busybox init) `exec` hota hai.
4. `/etc/inittab` → `::sysinit:/sbin/pk-boot` → hostname, `/etc/default/pk`, boot hooks
   (`/etc/pk-boot.d/S*`), optional DHCP/SSH, motd, aur `### PK: BOOT-OK ###` marker (serial QA ke liye).
5. `tty1-4` par `pk-console` → live me autologin, installed me `getty`+login.

**Live = ephemeral by design**: sab writes RAM overlay me, reboot pe reset.
Changes bachane ke do raaste: `persistent` boot option (USB pe hi partition) ya permanent install.

## 7. License / credit

MIT (see [LICENSE](LICENSE)). Isme koi nayi baat nahi — Linux kernel, busybox, squashfs-tools,
GRUB, xorriso, e2fsprogs, parted ka kaam ek saath joda gaya hai, sab apni-apni license pe.

## Users, devices aur desktop session (naya)

```sh
pk-user add bob --admin --password=bobpw   # user + audio/input/video/seat groups
pk-user autologin bob                      # tty1 par bob ka shell (password ke bina)
pk-user list ; pk-user info bob ; pk-user doctor
pk-user del bob --home
pk-desktop shot /root/desktop.png               # desktop ki screenshot (weston se)
pk-seatd status                             # session manager (weston ko VT/dri/input)
pk-check --users                            # add -> su -> del round-trip test
```

- Boot option se hi user + autologin: `pk_user=bob pk_userpw=pk` (live ISO me user tabhi
  bachega jab `persistent` ho ya system installed ho — live ka `/etc` RAM overlay hai).
- Live image me audio (`snd-hda-intel`, `snd-usb-audio`), bluetooth, webcam (uvc),
  sensors (hwmon), battery, thunderbolt/USB-C modules + `/etc/mdev.conf` se sahi
  device-group/mode (`/dev/snd`=audio, `/dev/input`=input, `/dev/dri`=video).
- Desktop: apps ISO + GRUB entry `g` (`pk_desktop=1`). weston **active VT** par seatd ke
  saath chalta hai -> screen par desktop. Marker: `DESKTOP-VT`, `SEATD-OK`, `DESKTOP-OK (wayland-1)`.

# pk's OS · BUILD — kaise banta hai, aur kya-kya chahiye

Source of truth: **https://github.com/risky-chokra/pkos** · release (base ISO, manifests,
git bundle): **https://github.com/risky-chokra/pkos/releases/tag/v1.0.0**

```sh
git clone https://github.com/risky-chokra/pkos.git && cd pkos
```

## Toolchain (Debian 12/13, Ubuntu 22.04/24.04)

```sh
sudo apt-get update
sudo apt-get install -y build-essential make busybox-static cpio squashfs-tools \
    xorriso mtools dosfstools parted e2fsprogs util-linux kmod \
    grub-pc-bin grub-efi-amd64-bin grub2-common initramfs-tools-core \
    linux-image-amd64 dropbear openssl
# optional lekin recommended
sudo apt-get install -y qemu-system-x86 ovmf        # emulator QA
sudo apt-get install -y debootstrap                  # App Runtime (build/pk-runtime.sqfs)
sudo apt-get install -y kbd                          # console keymaps (pk-keymap ka TTY part)
sudo apt-get install -y whois                       # mkpasswd (sha-512 hash, build time)
```

| tool | kyu chahiye |
|---|---|
| `mksquashfs` (squashfs-tools) | read-only root image |
| `xorriso`, `grub-mkrescue`, `grub-pc-bin`, `grub-efi-amd64-bin` | hybrid ISO (BIOS + UEFI) |
| `busybox-static` | init + live system ka 90% userland |
| `cpio`, `gzip` | initramfs packing |
| `parted`, `mkfs.ext4` (e2fsprogs), `mkfs.vfat` (dosfstools), `blkid`/`lsblk`/`losetup`/`findmnt` (util-linux) | ye binaries **live image ke andar** bhi jaati hain (installer ke liye) |
| `kmod` | depmod + live /lib/modules |
| `linux-image-amd64` | default kernel + uske modules |
| `qemu-system-x86`, `ovmf` | `make test` / `make run` |
| `dropbear` | live SSH (chhota, openssh se 100x chhota) |
| `grub2-common` (`grub-install`) | installer target disk pe GRUB daalta hai |

Doosre distro:
- **Fedora**: `sudo dnf install gcc make squashfs-tools xorriso grub2-pc-modules grub2-efi-x64-modules grub2-tools-extra mtools dosfstools e2fsprogs util-linux kmod cpio busybox-static kernel qemu ovmf`
- **Arch**: `sudo pacman -S base-devel squashfs-tools xorriso grub mtools dosfstools e2fsprogs util-linux cpio busybox qemu-full edk2-ovmf linux linux-headers`

Build host ka kernel hi live image me jaata hai — host pe `/lib/modules/$(uname -r)`
(naye kernel ke liye `linux-image-amd64` package) hona chahiye.

## Build pipeline

```
make iso
  └─ scripts/build-rootfs      rootfs/overlay + busybox + host bins + modules  -> build/work/rootfs
  └─ scripts/mk-squashfs       build/work/rootfs                               -> build/work/iso/live/pk.sqfs
  └─ scripts/mk-initrd         init/init + /mods + busybox + blkid               -> build/work/iso/boot/pk-initrd
  └─ scripts/mk-iso            kernel + initrd + sqfs + grub.cfg                -> build/pkos.iso
```

Har step ka apna stamp hai (`build/work/.stamps/`), isliye dobara-bara sab nahi banta.
`make clean-rootfs` stamps hata deta hai (agla build fresh).

### Kya-kya configurable hai

| file | knobs |
|---|---|
| `config/live.conf` | `OS_NAME`, `OS_VERSION`, `ISO_LABEL`, `HOSTNAME`, `LIVE_USER`, `LIVE_PASS`, `SQUASH_COMP`, `KERNEL_CMDLINE`, `INIT_MODULES`, `LIVE_BINS`, `LIVE_MODULES` |
| `config/live-bins.txt` | kaunsi host binaries live image me copy hon (parted, mke2fs, grub-*, dropbear, tar, gzip…) |
| `config/live-modules.txt` | live `/lib/modules` me kaun-kaun se modules jaayein (patterns, `find` se match) |
| `init/kernel-modules` | initramfs ke modules (boot-critical only — isko badhane se initrd bhaari hoti hai) |
| `init/grub.cfg` | ISO boot menu entries + options |
| `rootfs/overlay/**` | OS ka config + scripts (inittab, motd, pk-*, boot hooks) |

Env overrides (Makefile/se script):

```sh
make iso KERNEL_CMDLINE="quiet loglevel=3 pk_net=dhcp"   # default boot args
make iso SQUASH_COMP=xz                                      # zstd (default) / lz4 / xz / gzip
make iso PK_QEMU_MEM=3072                                 # QEMU RAM
make iso PK_KERNEL=build/kernel-6.12/bzImage PK_MODULES=build/kernel-6.12/lib/modules/6.12.0
make iso PK_FIRMWARE=1                                    # /lib/firmware bhi copy karo (badi ISO)
make iso WITH_RUNTIME=1                # build/pk-runtime.sqfs ko /live/ me daal do
sudo make runtime VARIANT=full         # App Runtime (debootstrap) — docs/APPS.md
```

## Image me kya jaata hai

```
ISO (hybrid, ~77 MiB)
├── boot/pk-kernel            host kernel (bzImage/vmlinuz)
├── boot/pk-initrd            /init + 44 boot modules (deduped, uncompressed .ko) + busybox + blkid, xz
├── boot/grub/grub.cfg           7 menu entries (BIOS+UEFI)
├── live/pk.sqfs              poora OS: busybox, config, scripts, 956 modules, grub, parted…
└── README.txt                   USB pe bhi padhne ke liye

live/pk.sqfs ke andar:
/bin/busybox                     static busybox (+ har applet ka symlink)
/sbin/pk-boot                 sysinit (mode, hostname, hooks, motd, autoinstall, selftest)
/sbin/pk-install              disk installer (GPT + ext4 + GRUB + fstab + password)
/sbin/pk-console, pk-halt  getty wrapper, shutdown helper
/sbin/pk-net, pk-ssh       DHCP, dropbear
/bin/pk-info/help/persist     user helpers
/etc/{inittab,passwd,shadow,issue,motd,profile,fstab,hostname,hosts,default/pk}
/etc/pk-boot.d/S*             boot hooks (S20net, S30ssh, S40persist)
/usr/share/udhcpc/default.script udhcpc ka script
/usr/sbin/{parted,mke2fs,e2fsck,tune2fs,blkid,lsblk,grub-install,…} + lib closure
/usr/lib/grub/{i386-pc,x86_64-efi}  taaki installed system ka bootloader ban sake
/lib/modules/<kver>              curated modules + depmod se generated modules.dep
/live-base → (bind)              pristine squashfs — installer yahi se copy karta hai
/live-iso → (bind)               boot media ka mount (README/ISO wapas padhne ke liye)
```

## Reproducibility

Reproducibility ke liye jo kiya gaya: `normalize_tree` (staged tree ke saare mtimes →
epoch 0), `cpio -O -H newc -R 0:0` (initrd me uid/gid 0), `mksquashfs -all-root`
(root:root, modes tree se), aur build-time `cp -p` (host binaries ke original mtime
preserve — inhe fix karne ke liye `collect-bins` ke baad `normalize_tree` chalana
kaafi hai). Do baar `make iso` se byte-identical ISO ki guarantee **nahi** hai
(xorriso apne timestamps daalta hai); content identical rahega. Full repro chahiye to
`SOURCE_DATE_EPOCH=0` export karo aur `mk-iso` me xorriso ko `-margin`/`-compliance`
ke saath `-publish_date` fix karo.

## Test / QA

```sh
make test                      # 7 stages, ~10 min (TCG emulation, 640 MB VM)
make test-apps                 # sirf stage 7 (apps layer), ~30 s
make check                     # sirf stage 8 (pendrive kit)
make gui-test                  # stage 8 + desktop/X client round-trip
make manifest                  # build/manifest.txt = payload sha256 (rebuild verify)
make iso REPRODUCIBLE=1        # SOURCE_DATE_EPOCH se squashfs+initrd byte-stable
make bundle                    # git bundle + src tar (machine-to-machine transfer)
make test-live                 # sirf stage 1 (fast smoke test)
PK_TEST_STAGES=2,3 make test  # install + installed boot
PK_TEST_TIMEOUT=400 make test # slow machine pe
cat build/test-logs/*.log        # har VM ka serial output
```

Stages: (1) live boot from ISO (grub) · (2) headless install → disk image ·
(3) us disk ka apna GRUB se boot + installed-mode policy checks · (4) `toram` ·
(5) UEFI/OVMF · (6) `persistent` disk + `pk_net=dhcp` + `pk_ssh=on` ·
(8) **Pendrive kit** (kit ISO jisme runtime andar; `pk-check` 0 FAIL, `pk-keymap`,
headless install with `--user` + runtime copy, phir installed boot par
`/var/lib/pk` se rw-image attach) · `make gui-test` se stage 8 + desktop session
(weston → Xvfb fallback + `xterm`/`xdpyinfo` round-trip) ·
(7) **App Runtime** (runtime disk se `/opt/pk` attach + `pk-run` dispatch battery +
doosri boot par re-attach + host side `pk-runtime-rw.img` ke andar installed app verify)
(stage 6 do baar boot karta hai: marker file persist image me likhti hai, dusri
boot me wahi file padhi jaati hai + host side `mkfs` image me file verify hoti hai).
Ek stage dobara: `PK_TEST_STAGES=6 make test`.
Markers (`### PK: BOOT-OK ###`, `INSTALL-OK`, `SELFTEST-OK`,
`DEPS-OK`, `PASSWD-OK`, `LOGIN-REQUIRED`, `NET-OK`, `SSH-OK`,
`PERSIST-WROTE`/`PERSIST-KEPT`, apps layer ke `RUNTIME-OK`/`RUNTIME-WARN`/`APPS-OK`/
`APP-DEB-OK`/`APPS-GET-OK`) serial log me dhoonde jaate hain —
isliye **wahi markers real PC par debug karte waqt bhi kaam aate hain**:

```sh
dmesg | grep PK          # /dev/kmsg me bhi jaate hain
```

## Common build errors

| error | matlab | fix |
|---|---|---|
| `/boot/vmlinuz-* nahi mila` | host pe kernel package nahi | `sudo apt install linux-image-amd64` |
| `grub-mkrescue fail` | grub-pc-bin/grub-efi ya xorriso missing | upar wala apt line |
| `initrd staging: No such file or directory` | `make initrd` se pehle `make live` skip hua | `make iso` (ya `make clean-rootfs && make iso`) |
| `! not on host, skipping: xyz` | wo tool host pe nahi, live image me nahi jayega | us package ko install karo ya `config/live-bins.txt` se hatao |
| ISO 4 GiB se badi ban rahi | `-allow-limited-size` lagega | `SQUASH_COMP=xz` karo ya `config/live-modules.txt` trim karo |

## Headless / no-screen VM ke liye ISO (serial console default)
```sh
make iso OUT=build/pkos-serial.iso PK_SERIAL=1
```
`PK_SERIAL=1` default GRUB entry me `console=tty0 console=ttyS0,115200n8` add karta hai, isliye
VirtualBox/VMware me screen na bhi dikhe to serial-port->file me GRUB menu + kernel log +
`### PK: …` markers + live root shell mil jaati hai (VM-TEST.md me VBox ki `--uartmode1 file` trick).

## Initrd ka busybox STATIC hona zaroori hai
`scripts/mk-initrd` ab check karta hai: dynamic busybox milne par **die** (pehle wo initrd me
chala jaata tha aur `/init` -> `Attempted to kill init!` kernel panic deta tha — screen bilkul khali).
Jaante-bujhke dynamic chahiye to `PK_ALLOW_DYNAMIC_BUSYBOX=1` (initrd me lib closure khud copy ho jaata hai).

## /tmp chhota hai to ISO build fail (`No space left on device`)

`grub-mkrescue` staging ke liye `$TMPDIR` use karta hai; 1 GB tmpfs (containers, live
USB par build) me ye bharr jaata tha. Ab `scripts/mk-iso` khud `TMPDIR=$WORK/tmp`
(build/ ke andar, disk-backed) set kar deta hai — extra kuch karne ki zaroorat nahi.
Apni marzi se badalna ho to: `TMPDIR=/mnt/big make iso`.

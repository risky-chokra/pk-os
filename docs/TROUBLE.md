# pk's OS · TROUBLE — debug guide (initramfs shell se installer tak)

Sabse pehle: **`pk-check --save`** chalao (live system me) — ye net/USB speed/disks/DRM/KVM/
SecureBoot/runtime/wine/dmesg ka ek table banata hai aur report `/run/pk/check.txt`
(+ `/tmp/pk-check.txt`) me likh deta hai. Debug karne ke liye yahi sabse tez hai.

Uske baad: **markers padho**. Live system har milestone `/dev/kmsg` me likhta hai,
isliye ek boot ke baad bhi poori kahani milti hai:

```sh
dmesg | grep -iE 'pk|BOOT FAIL'          # boot ka trail
cat /run/pk/{mode,media,rootdev,cmdline} # init ne kya decide kiya
cat /run/pk/dmesg-boot.log               # initramfs ka full dmesg (handoff se pehle)
tail -50 /run/pk-install.log             # headless install ka output
```

## 1. Boot atka / "BOOT FAIL" — initramfs shell use karo

Do options (GRUB me entry select karo, ya `e` se `linux` line me add karo):

```
pk_debug          # init ka set -x, har command dikhega
break=mount          # root mount karne se PEHLE initramfs shell
```

Shell me diagnosis:

```sh
ls /sys/block                        # disks dikhi? (vda/sda/nvme0n1)
cat /proc/partitions                 # partitions + sizes
cat /proc/cmdline                    # kernel ko kya params mile
ls /mods                             # initrd ke modules
lsmod | head -20                     # kaun load hua
dmesg | tail -40                     # driver errors
# live image manually dhoondo:
mkdir -p /mnt/media
mount -o ro -t iso9660 /dev/sr0 /mnt/media        # ya /dev/sdb, /dev/sdc1 ...
ls /mnt/media/live/pk.sqfs                      # file honi chahiye
mount -o ro -t squashfs /mnt/media/live/pk.sqfs /ro
ls /ro/sbin/init                                     # -> run-init ke liye tayyar
exit                                                 # boot continue karo
```

Common reasons:
- **disk nahi dikhi** (`ls /sys/block` khaali) → storage driver missing. Purane IDE/laptop
  pe `ata_piix`, naye Intel pe VMD/RST (BIOS me `AHCI` karo), NVMe firmware RAID mode me
  ho sakta hai. Custom kernel banate waqt `init/kernel-modules` me driver add karo.
- **sqfs nahi mila** par disk dikhi → ISO *file* ko kisi partition me copy kiya hai (dd
  nahi ki)? To `/live/pk.sqfs` us partition me hona chahiye, aur `pk_media=/dev/sdX1`
  dekhkar exact device bata do.
- **loop/squashfs mount fail** → kernel me built-in nahi aur /mods me nahi. Host kernel
  me Debian inhe module rakhta hai — init unhe `/mods` se load karta hai; custom kernel
  me `CONFIG_BLK_DEV_LOOP=y CONFIG_SQUASHFS=y CONFIG_OVERLAY_FS=y` (build-kernel already
  karta hai).
- **overlay fail** → `upperdir/workdir` same filesystem pe hone chahiye, aur `work`
  directory khaali. `mount -t overlay` ka error padho.

## 2. Installer ke issues

```sh
pk-install --info                       # target + disks dikhaega
sudo pk-install --target=/dev/sda --yes --no-bootloader   # sirf partition+copy
cat /run/pk-install.log                   # headless run ka log
parted -s /dev/sda print free                 # layout dekho
blkid /dev/sda3                                # UUID exist karta hai?
```

| marker | matlab |
|---|---|
| `### PK: INSTALL-OK target=... root=... ###` | success |
| `### PK: INSTALL-FAIL: no-target ###` | internal disk nahi mili → `--target=/dev/sdX` ya `PK_ALLOW_REMOVABLE=1` |
| `### PK: INSTALL-FAIL: copy fail ###` | tar/copy fail — space, ya `/live-base` bind nahi mila |
| `### PK: INSTALL-FAIL: grub-install ...` | grub module/libs missing — live image me `grub-install` + `/usr/lib/grub/<target>` chahiye |
| `INSTALL-DONE rc=N` (autoinstall) | installer ka exit code; N≠0 → log dekho |

Copy manually karni pade to:

```sh
sudo mount /dev/sda3 /mnt
sudo mount /dev/sda2 /mnt/boot/efi
sudo sh -c 'cd /live-base && tar -cf - --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./run . | (cd /mnt && tar -xpf -)'
sudo cp /live-iso/boot/pk-kernel /live-iso/boot/pk-initrd /mnt/boot/
grep root= /proc/cmdline   # UUID khud nikaal ke fstab/grub.cfg me daalo
sudo grub-install --target=i386-pc --boot-directory=/mnt/boot /dev/sda
```

## 3. GRUB / boot menu

- `grub.cfg` template: `init/grub.cfg` (build me `@ARGS@`, `@VER@`, `@LABEL@` substitute hote hain).
- Boot karte waqt `e` → `linux` line edit → params add karo → `Ctrl-x` boot.
- Timeout/Default: `config/live.conf` me `KERNEL_CMDLINE`; entries `init/grub.cfg` me.
- **UEFI me entry nahi dikhi** → `--removable` install `EFI/BOOT/BOOTX64.EFI` banata hai;
  firmware me "Boot from file" se manually select karo; phir `efibootmgr` se entry bana lo.

## 4. QEMU (build/test)

```sh
make run                          # headless: serial stdio pe (ctrl-a x se band)
make run-tty                      # jo terminal me ho, wahi
make run-efi                      # OVMF UEFI
# direct kernel boot (grub skip) - fastest iteration:
scripts/run-qemu.sh -iso build/pkos.iso -kernel build/work/iso/boot/pk-kernel \
  -initrd build/work/iso/boot/pk-initrd \
  -append "console=ttyS0 loglevel=7 pk_debug break=mount" -tty
# ek disk image pe install + boot:
dd if=/dev/zero of=build/disk.img bs=1M count=4096 status=none conv=sparse
scripts/run-qemu.sh -iso build/pkos.iso -hdd build/disk.img \
  -append "console=ttyS0 pk_install=/dev/vdb pk_halt" -tty
```

Sandbox/nested-VM environment me `/dev/kvm` nahi milta → QEMU TCG se boot 60-90s
lagta hai; `make test` ka timeout (`PK_TEST_TIMEOUT=220`) isi hisaab se hai.
Host pe KVM ho to `make run` me `-accel kvm` add kar do (run-qemu.sh me `PK_QEMU_EXTRA`).

## 4b. Desktop (weston) screen par nahi aaya

Pehle **marker** dekho — ye batata hai ki display subsystem ne kya paya:

```
dmesg | grep -a 'PK: DISPLAY'        # ya boot ke waqt serial log
cat /run/pk/display.txt              # final status: fb=N drm=N driver=X
grep -a pk-display-status /etc/motd  # login screen ke upar bhi yehi dikhta hai
```

| Kya dikha | Matlab | Kya karo |
|---|---|---|
| `DISPLAY-NO-RUNTIME` (GRUB ke baad) | aap base/serial ISO chala rahe ho — weston/xterm App Runtime me hote hain | `pkos-1.0-apps.iso` use karo, ya `pk-runtime --setup <file>` se runtime lagao |
| `DISPLAY-TEXTONLY (fb=0 drm=0 ...)` | koi KMS device nahi -> weston ke paas /dev/dri/card0 nahi | VM ka graphics device badlo (`-vga std` / `-vga virtio`; VBox me `vmsvga`), ya `pk-desktop vnc 5900` |
| `pk-x: ... weston HEADLESS par chal raha hai` | session utha par physical screen nahi | `pk-x stop; pk-x start Xvfb` phir `pk-desktop vnc 5900` |
| `DISPLAY-KMS (drm=1 driver=...)` par phir bhi kaali screen | `pk_desktop=1` nahi tha (default live entry desktop *start nahi karti* — base ISO tez rahe) | GRUB menu me entry 5 (`live: desktop + apps GUI`) chuno, ya login ke baad `pk-desktop start` |
| `DESKTOP-OK (:0)` (yaani Xvfb) par KMS device maujood | weston start fail hua (ab iska reason `DESKTOP-WESTON-LOG` marker me dikhta hai) | `pk_run=cat+/run/pk/x-weston.log` se log padho; runtime me `weston` + `fonts-dejavu-core` hone chahiye: `pk-get install -y weston fonts-dejavu-core` |
| kernel log: `vmwgfx ... probe with driver vmwgfx failed with error -38` | QEMU ka emulated VMware SVGA purana (v2) hai, kernel reject karta hai | `-vga vmware` chhodo; `-vga std`/`-vga virtio` use karo (asli VMware/VBox par vmwgfx chalta hai) |

```
pk-desktop status      # session/Xvfb ke baare me + weston.ini
pk-x status            # konsa display server chala (weston/Xvfb) + log
pk-check --gui         # GUI round-trip test (xterm khola, screenshot/exit check)
```

## 5. Root password bhool gaye (installed system)

Live USB se boot karo, phir:

```sh
sudo mkdir -p /mnt && sudo mount /dev/sda3 /mnt      # ya blkid se UUID dekhkar
sudo chroot /mnt /bin/busybox passwd root            # naya password
# chroot me /dev mount karna pade to:
for d in dev proc sys; do sudo mount --bind /$d /mnt/$d; done
```

## 6. Network / SSH ka masla

pk's OS me **udev nahi hai** — isliye NIC driver khud load karna padta hai. Boot hook
`/etc/pk-boot.d/S20net` → `pk-net dhcp` yehi karta hai (modprobe list, phir udhcpc).

```sh
ls /sys/class/net              # NIC dikha? nahi -> driver load nahi hua
dmesg | grep -iE 'virtio|eth|failover|unknown symbol'
pk-net status               # har NIC: operstate + IP + dns
pk-net dhcp                 # dobara try karo (output console + /var/log/pk-net.log par)
cat /var/log/pk-net.log
ip route show; cat /etc/resolv.conf
```

- **NIC hi nahi dikhti** → uska driver `config/live-modules.txt` me nahi hai.
  Pattern add karo (jaise `kernel/drivers/net/ethernet/marvell`) aur `make clean-rootfs && make iso`.
  Boot-critical drivers initrd me jaan boojh kar nahi hain (initramfs ko net chahiye hi nahi).
- **`Unknown symbol` / driver load fail** → dependency module live rootfs me nahi.
  `scripts/build-rootfs` host ke `modules.dep` se closure khud expand karta hai;
  apna kernel use kar rahe ho to us tree ka `modules.dep` hona chahiye.
- **`udhcpc rc=0` par IP nahi** → `/usr/share/udhcpc/default.script` missing/executable nahi
  (yahi script IP/route/DNS apply karti hai). Busybox ka compiled-in default path
  `/etc/udhcpc/default.script` hai — build-rootfs wahan symlink bhi rakhta hai.
- **DHCP slow network me timeout** → `pk-net` me `-t 10` (10 discover packets).
  Badhane ke liye `udhcpc -i <if> -s /usr/share/udhcpc/default.script -t 30 -T 3 -n -q`.
- **Wi-Fi** yaad rakho: live image me firmware nahi hoti (default). `make iso PK_FIRMWARE=1`
  se `/usr/lib/firmware` copy ho jaati hai, phir `ip link set wlan0 up` + apna supplicant.
- **SSH nahi chala** → `pk_ssh=on` (ya installed system me `/etc/default/pk` me
  `PK_SSH=yes`), phir `pk-ssh start`; host key first boot par banta hai
  (`/etc/dropbear`), isliye pehle connect me fingerprint badalta hai.

## 7. Image chhoti/badi karni hai

- **chhoti**: `config/live-modules.txt` trim karo (network/Wi-Fi/gpu patterns hata do —
  network patterns hataane par `pk_net=dhcp` bekaar ho jaayega),
  `make iso SQUASH_COMP=xz` (zstd se ~10% chhoti, boot thoda slow), `PK_FIRMWARE` off (default).
- **badi/chhoti ka farak**: kernel modules 60 MB uncompressed → ~25 MB compressed;
  busybox + tools + grub sirf ~6 MB.
- grub-mkrescue 4 GiB se badi ISO par `-allow-limited-size` lagaata hai (xorriso) —
  modules + firmware sab daal do to ISO 4 GiB ke paar ja sakti hai; USB fat32 me
  4 GiB single-file limit hoti hai, par hum **raw dd** karte hain isliye problem nahi.

## 8. Report karna

`build/test-logs/*.log` (QA), `dmesg`, aur exact kernel cmdline + `pk-info` ki output
attach karo — in teen me se zyadatar masla turant dikh jaata hai.

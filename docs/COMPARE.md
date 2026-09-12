# pk's OS · REFERENCE-OS comparison (live-boot hardware matric)

Kyun: hamara goal "har PC/desktop pe chale" hai. Live distros ye maamle saalon se
seekh chuke hain, isliye unka architecture hamare init/initrd se compare kiya aur
jo kami mili wahi add ki (kuch bhi hataaya nahi gaya).

| reference | uska live-boot model | hamara pk's OS | verdict |
|---|---|---|---|
| **Alpine Linux** (mkinitfs + `aodela`/`liveinit`) | tiny initramfs; `realroot` retry + `rootdelay`; mediacfg me fs-type list; `sda`+partitions scan; **frugal**: `apline-mod` ISO/directory dono se | init me `list_devices` (disks + partitions) + naye `rootdelay=` retry loop (default 12 s) + `try_sqfs_here` + frugal `try_iso_file` | ✅ ab barabar (pehle retry-only- installed path me tha, aur frugal nahi) |
| **ArchISO** (mkinitcpio + `archiso` hook) | `work_directory=arch/boot/x86_64/airootfs`, devmapper + **overlayfs** on `/run/archiso/airootfs`, `cow_spacesize`, `archisobasedir`; USB boot ke liye initrd me `vfat/exfat/nls` + `usb_storage` | `/live/pk.sqfs` scan (5 path variants), overlayfs upper = RAM/`PK-PERSIST`, initrd me storage+input+nls modules | ✅ same idea; hamare paas extra: 3 runtime locations + `pk_verify` |
| **Fedora live** (dracut + `dmsquash-live`) | `live_image_uuid=` se **media dhoondhta hai (UUID!)**, `live_dir=LiveOS`, `rd.live.squashimg`, `rootdelay`, `rd.retry`, `mem=...toram` (`live_memainscratch`), checks `rd.live.check` | `pk_media=<dev|UUID=x|LABEL=x>` (already supported) + `persistent` + `toram` + ab `rootdelay=` | ✅ parity (aur naya: payload sha256 `pk_verify` = unka `rd.live.check` se behtar, since we hash the squashfs) |
| **Ubuntu casper** | `find_livefs` loop: retries until `CASPER_TIMEOUT`(30 s default), `iso-scan` for **ISO-file-on-partition** boot (ubiquity/frugal), `nopersistent`, `boot=casper` | pehle koi retry nahi tha live ke liye; ab `rootdelay` + frugal loop | ✅ ab parity (casper ka `iso-scan` hi hamara `try_iso_file` hai) |
| **TinyCore** | `scan=/dev/sd*` mount karke `*.iso`/`cde/*.tcz` dhoondhta hai, `basefile=`, `wait=XX` seconds, `restore` | `pk_iso=<naam>` se specific file, auto-scan `*.iso`, `rootdelay=` as `wait=` | ✅ |
| **SystemRescue / GRML** (Debian-based) | initrd me `usb-storage`, `uas`, `xhci`, `sr_mod`, `cdrom`, `vfat/exfat/ntfs3`, keyboard ke liye `usbhid`; `dovolume=`/`archisobasedir`-jaisa label; admin toolset (fsck/gddrescue/smartctl) | initrd me same storage+input set + ab `ntfs3`, `nls_cp437`, `nls_utf8`, `msdos`; live image me `lsblk`(naya), `wipefs`, `blkdiscard`, `dumpe2fs`, `setfacl`, `mksquashfs`; `pk_media=`/`pk_iso=` | ✅ + hamare paas unke jaisa "boot par network+SSH" bhi hai (`pk_net=dhcp pk_ssh=on`) |
| **Ventoy** (boot manager) | ISO ko **file ki tarah** partition me rakhta hai, dm-mapper device deta hai (`/dev/mapper/ventoy`) | ab frugal ISO-file boot supported + `list_devices` me `/dev/mapper/*`, `/dev/dm-*` bhi scan hote hain | ✅ (pehle mapper devices scan me nahi aate the) |
| **Debian/Ubuntu installer ISO** | EFI `\EFI\BOOT\BOOTX64.EFI` + `el-torito` hybrid, `.disk/info`, grub-mkrescue | hybrid ISO (BIOS+UEFI+protective GPT), `.disk/` + `README.txt` + `SHA256SUMS` | ✅ |

## Aaj is comparison se kya-juda fix hua (sirf add hua, kuch hataaya nahi)
1. **`nls_cp437`, `nls_utf8`, `msdos`, `ntfs3` initrd me** ( + `kernel/fs/unicode` live modules me;
   Debian ka `vfat` inhein runtime me maangta hai — `modules.dep` me dep nahi hota, isliye
   hamara dep-closure nahi laata tha) → **FAT32/exFAT pendrive partition se boot** ab kaam karta hai.
   Proof (QEMU): `live base: /live/pk.sqfs from /dev/vda1 (fs=vfat)` → `### PK: BOOT-OK ###` ✓
2. **mount option variants + auto-detect fallback** (`vfat:ro,utf8`, `iocharset=utf8`, `auto:ro`) —
   images/kernels ke bhed se `EINVAL` aata tha (ye upar wale fix ko complete karta hai).
3. **`rootdelay=`/`pk_rootdelay=` + live-media retry loop** (default 12 s): slow USB3/mmc readers
   par devices 2-8 s me aate hain; pehle ek hi scan hota tha → real hardware pe "media nahi mila" ka risk.
4. **Frugal / ISO-file boot**: partition me sirf `pkos*.iso` (ya koi bhi `*.iso`) para ho to loop-mount
   karke `/live/pk.sqfs` nikaal lete hain; `pk_iso=<naam|path>` se pin bhi kar sakte ho.
   Proof: `live base: /live/pk.sqfs from /dev/loop0 (fs=iso9660)` → `BOOT-OK` ✓ (Ventoy/hard-disk flow)
5. **`/dev/mapper/*` + `/dev/dm-*` candidates** me add (Ventoy/dm devices) + extra live paths
   (`/boot/live/pk.sqfs`) + extra fs types (`btrfs`, `f2fs`, `msdos`).
6. **`pk_fsdebug=1`** (init diagnostics): har failed media-mount ka asli error, device ka size +
   first-sector bytes, aur `insmod` failures console par. Aise bugs ("screen hi nahi aayi") field me
   2 minute me diagnose ho jaate hain.
7. **`mk-initrd`: static-busybox ka hard check** — dynamic busybox initrd me jaake `/init` ko
   panic karta tha (blank screen!); ab build hi clear message ke saath fail hota hai,
   `PK_ALLOW_DYNAMIC_BUSYBOX=1` par lib closure copy karke chalta bhi hai.
8. **`lsblk`/`findmnt`/`wipefs`/`blkdiscard` live image me** (SystemRescue/Alpine jaisa admin set);
   `pk-check` ka purana `/sys` fallback waisa hi rahega (dependent cheezein tooti nahi).

## Jaan-boojh ke NAHI kiya (aur kyun)
- **Network boot (PXE/NFS/iSCSI)** — Alpine/Fedora karte hain; hamara target "pendrive + install" hai,
  aur initrd me `ip=dhcp`/nfs add karna size + complexity badhaata hai (maango to bana denge).
- **dm-snapshot `cow` persistence** (Arch/Fedora) — hamara overlayfs-upper (`persistent`) simpler aur
  ext4/vfat dono pe chalta hai; `cow` ka koi fayda nahi mila jo na mil raha ho.
- **`live_dir` naming** (Arch/Fedora style) — hamara path set chhota rakha; 5 variants support me hain.
- **Graphical boot splash / plymouth** — base ISO me X nahi (design); `pk-desktop` session deta hai.
- **Squashfs `dm-verity` + signed boot** — payload sha256 (`pk_verify`) diya, poora verified-boot
  TPM/MOK round hai (roadmap me).

- **Users + device access ka scene**: reference OS me user management ya to absent hai ya
  manual (`/etc/passwd` edit). Hamare live me `pk-user add/remove/autologin` hai aur naye
  user ko audio/input/video/seat groups milte hain, isliye wo bina root ke sound, keyboard/mouse
  events aur GPU use kar sakta hai; `pk-check --users` ye round-trip khud test karta hai.
- **Session manager**: hamein chahiye tha ki weston screen le - isliye `seatd` (30 KB,
  runtime ke andar) + active-VT handling; iske bina weston bina VT liye headless ban jaata tha.

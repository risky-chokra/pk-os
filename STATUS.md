# pk's OS · STATUS (aaj kya hua, kahaan tak pahunche)

> Ek-file recap. Detail chahiye to `README.md` + `docs/` (khaas kar
> **docs/PENDRIVE.md** — aapke real pendrive test ka sheet).

## 1. Kya bana

Apna chhota Linux OS jo **x86_64 PC pe live USB se boot hota hai aur permanent install
bhi ho jaata hai** — koi distro installer nahi, sab isi repo se build.

```
busybox-static + squashfs (read-only /) + overlayfs (upper = RAM / PK-PERSIST partition)
+ custom initramfs /init (boot media khud dhoondhta hai)
+ hybrid ISO (grub-mkrescue: BIOS + UEFI, dd-able)
+ /sbin/pk-install  (GPT: bios_grub + ESP + ext4, GRUB i386-pc + x86_64-efi, fstab by UUID,
                     non-root user, app runtime copy)
+ App Runtime       (/opt/pk = Debian squashfs + rw overlay -> apt/dpkg/Wine/GUI apps)
+ pk-run dispatcher (ELF · script · .deb · .rpm · AppImage · .jar · .exe/.msi[Wine] · .ipa · .apk)
+ live kit          (pk-check · pk-desktop · pk-keymap · pk-wifi · pk-ios · pk-android)
+ boot hooks        (net+DHCP, dropbear SSH, persistence, runtime, keymap, check, desktop)
```

## 1c. Modern-desktop spec pass (aaj ka doosra round) → `docs/ARCHITECTURE.md`

Aapki 7-section requirement list ko item-by-item map kiya (kaun deliver karta hai + verify
command + status). Code me jo **add** hua:

| spec item | kya bana | QA proof |
|---|---|---|
| 1.3 interactive foreground priority | `pk-tune desktop`: cgroup v2 `pk.slice/apps` = `cpu.weight 200`, `bg` = 20, `sched_autogroup=1`, governor powersave + EPP; `pk-desktop` compositor + `pk-desktop app` clients ko apps slice me daalta hai; manual `pk-tune fg|bg <pid|name>` | `TUNE-REPORT-OK` ✓ |
| 1.4 P/E (heterogeneous) awareness | `pk-tune hybrid`: `cpu_capacity` se big(≥900)/little(≤700) split → `cpuset.cpus` (daemons little par). VM me `uniform` aata hai — expected | ✓ |
| 2.3 dynamic HiDPI + multi-monitor | `pk-desktop outputs` (DRM se modes), `scale 2 [OUT]`, `mode`, `transform`, `arrange`, `restart` → `weston.ini` runtime me likhta hai, reboot nahi | ini-merge test ✓ |
| 3.1 demand paging + swap | `pk-tune swap [MB]` (holes-free swapfile → mkswap → swapon; sparse swapfile valid nahi hota) | ✓ |
| 3.3 journaling | installer `dumpe2fs` se ext4 `has_journal` verify karta hai | `INSTALL-JOURNAL-OK` ✓ (stage 2) |
| 4.2 plug & play drivers | **`S15mdev` hook**: `mdev -s` coldplug + `uevent mdev` netlink listener + `hotplug.sh` me `modprobe $MODALIAS`. Pehla version `/proc/sys/kernel/hotplug` par depend tha aur silent exit karta tha (VM test me pakda) → ab listener wala sahi raasta | `MDEV-OK (uevent listener + coldplug, rc=0)` ✓ VM me verified |
| 5.3 app sandboxing | `pk-run --sandbox` = user/mnt/pid/ipc/net namespaces + tmpfs over `/root /home /mnt/persist` + ro remount try; kernel user-ns na de to `APP-SANDBOX-UNAVAIL` (boot/app kabhi nahi rokta) | `APP-SANDBOX-OK` ✓ (leak assert ke saath) |
| 5.4 root of trust (partial) | `mk-iso` → `/live/pk.sqfs.sha256` + `/live/pk-runtime.sqfs.sha256` + ISO-root `SHA256SUMS`; init `pk_verify=1` par hash match (warn) / `pk_verify=require` par **boot rok deta hai** | `VERIFY-OK` ✓ (stage 1) |
| 6.2 foreign-arch binaries | `pk-binfmt status|register|unregister` (binfmt_misc handlers `pk-aarch64/arm/riscv64/ppc64le/s390x`) + `pk-run` e_machine(offset 18) parse → qemu-user se dispatch; `binfmt_misc`+`cpufreq` modules live image me | `ARCH-DISPATCH-OK` ✓ |
| 7.1/7.2 net + IPC | `pk-tune net` (rmem/wmem 16 MiB, `fq`, BBR, TCP_FASTOPEN, jumbo) + `pk-tune ipc` (`/dev/shm`, POSIX mqueue, `io_uring_disabled=0`) | ✓ |
| security observability | `pk-tune report`: ASLR/`ptrace_scope`/lockdown/CPU-vuln count/TPM device/hotplug/swap/cgroup rows | ✓ |

**Full 8-stage suite: QA PASS 64 checks ok** (stage 2 = 8, stage 7 = 14, stage 8 = 19 ✓) ·
asli 617 MiB desktop runtime ke saath `make gui-test`: **QA PASS 22 checks ok** (GUI + tune +
binfmt + arch sab green) · GitHub release ke 7 assets ke sha256 = local files se **MATCH** ✓.
🚫 jo is design/hardware par possible nahi (reason ke saath doc me): Secure Boot signing +
TPM measured boot ka poora round, VBS (type-1 hypervisor neeche chahiye — alternative:
`pk-vm` se app-in-VM), LSM/RBAC policy, DirectStorage GPU-P2P, kernel EAS integration,
iOS native (Mach-O + closed UIKit). Roadmap: `docs/ARCHITECTURE.md` §9.

## 2. Aaj ka round (iOS + "sab add karo sahi se")

| cheez | status |
|---|---|
| `make doctor` | sab ready (0 missing) |
| `make iso` | `build/pkos.iso` = **87 633 920 bytes (84 MiB)** (delivered `pkos-1.0.iso` isi size ka) |
| `make test` (QEMU, **8 stages**) | **QA PASS 64 checks ok**, rc=0 (+6 is round: verify, mdev, tune, binfmt, journal, sandbox/arch) |
| `make gui-test` (stage 8 + desktop runtime) | **QA PASS 22 checks ok** — GUI + pk-tune + pk-binfmt + foreign-arch ✓ |
| `make apps-iso` | `build/pkos-apps.iso` = **700 MiB** (App Runtime + apt + Wine + weston/Xvfb andar) |
| `make iso REPRODUCIBLE=1` | do alag builds ke `/live/pk.sqfs` + `/boot/pk-initrd` **sha256 same** ✓ |
| git | **3 commits** (sandbox reset ke baad dobara init), **78 files tracked**, tree clean |
| aapke liye files | `/home/user/pkos-1.0.iso` (87 633 920 B, sha256 `f1b5c1f3…`) ✓ persist + verified, `pkos-1.0-manifest.txt` + `pkos-1.0-apps-manifest.txt`, `pkos-1.0-src.tar.gz`, `pkos-1.0.bundle`, `pkos-1.0.iso.sha256` (4 entries, `sha256sum -c` OK). **`pkos-1.0-apps.iso` (700 MiB) size cap se persist nahi hota** -> `sudo make runtime-desktop && make apps-iso` se 6-8 min me dobara |
| is round me naya | `pk-check`, `pk-desktop`, `pk-keymap`, `pk-wifi`, `pk-ios`, `pk-android`, `tools/verify-usb.sh`, `scripts/manifest.sh`, `tools/restore-from-iso.sh`, QA **stage 8**, `docs/PENDRIVE.md`, `docs/IOS-ANDROID.md` |

### QA stages (sab pass)

| stage | proof |
|---|---|
| 1 live boot | grub → kernel → initrd → squashfs+overlay → init, `DEPS-OK`, base ro, installer tools |
| 2 headless install | `INSTALL-OK`, `INSTALL-DONE rc=0`, installed tree + `root=UUID=` + root hash (sha-5) host se verify, DHCP on |
| 3 installed boot | apne GRUB se boot, `PASSWD-OK`, `LOGIN-REQUIRED` (autologin nahi) |
| 4 toram | image RAM me copy, media reuse ke saath boot |
| 5 UEFI (OVMF) | GPT/ESP path |
| 6 persistence + net + ssh | `PERSIST-WROTE`/`PERSIST-KEPT`, `upperdir=/mnt/persist/…`, `NET-OK (ip)`, `SSH-OK` |
| 7 app runtime | runtime attach, `pk-run` battery (ELF/script/.deb/.exe/.apk/Mach-O/**.ipa**/AppImage/jar/rpm), chroot exec, doosri boot par re-attach, host se rw-img verify — **14 checks** |
| 8 pendrive kit | kit ISO (runtime andar) → `pk-check` **0 FAIL**, `pk-keymap`, headless install with `--user` + runtime copy (`/var/lib/pk`), installed boot par **`mode=rw-image`** persistence — **15 checks**; `PK_TEST_GUI=1` se +4: `DESKTOP-OK`, `GUI-X-OK`, `GUI-APP-OK` (xterm), `GUI-XCLIENT-OK` (xdpyinfo) |

## 2a. GitHub pe push ho gaya ✓

| | |
|---|---|
| repo | https://github.com/risky-chokra/pkos (public, default branch `main`, 78 files) |
| tag | `v1.0.0` -> commit `9af942b` |
| release | https://github.com/risky-chokra/pkos/releases/tag/v1.0.0 |
| assets | `pkos-1.0.iso` (87 633 920 B) + `pkos-1.0-manifest.txt` + `pkos-1.0-apps-manifest.txt` + `pkos-1.0.iso.sha256` + `pkos-1.0-src.tar.gz` + `pkos-1.0.bundle` |
| verify | release se ISO dobara download karke `sha256sum` milaya: `f1b5c1f3…` **byte-identical** ✓ |
| not in release | 700 MiB apps+wala ISO (bada asset) — `sudo make runtime-desktop && make apps-iso` se ban jaata hai |

## 2b. Reset ke baad restore (aapke PC pe bhi wahi 2 command)

```sh
git clone https://github.com/risky-chokra/pkos.git pkos   # (ya bundle se: git clone pkos-1.0.bundle pkos)
cd pkos && make doctor && make iso    # toolchain chahiye: apt list docs/BUILD.md me
sudo make runtime-desktop && make apps-iso   # 700 MiB wala apps+GUI ISO dobara
```
Sandbox me bade files (700 MB ISO, `build/`) persist nahi hote — chhote (src tar,
bundle, manifests, base ISO) persist hote hain, isliye wahi backup hain.

### 2c. Aapke VirtualBox test se nikle 2 asli bug (aaj fix + VM me verify)

| bug | lakshan | fix |
|---|---|---|
| `udhcpc` ka `default.script` git me **644** (exec bit nahi) | `udhcpc rc=0`, lease milta hai, phir bhi `### PK: NET-FAIL ###` — fresh clone se build karne par network toot jaata | `build-rootfs` ab stage karte waqt usse (aur `etc/init.d/pk-boot`) 755 karta hai + index me bhi `+x`; VM me `NET-OK (10.0.2.15)` + `SSH-OK` ✓ |
| `S15mdev` legacy `/proc/sys/kernel/hotplug` sysctl par depend, silent exit | docs me `MDEV-OK` claim, par image me koi marker nahi | busybox `uevent mdev` netlink listener + `mdev -s`; har branch print karta hai → `MDEV-OK (uevent listener + coldplug, rc=0)` ✓ |

(Aapki VM ki asli problem kuch aur thi: VirtualBox me **UEFI + Secure Boot ON** tha — `VBox.log` me
`Firmware type: UEFI / Secure Boot: Enabled`. Hamara GRUB unsigned hai isliye OVMF use load hi
nahi karta. Fix: Settings → System → Motherboard → **Enable Secure Boot untick** (EFI rakhna ho)
ya **Enable EFI untick** kar do (BIOS path QA me verified hai ✓). ISO aapke VM me sahi attach thi:
VBox log ka `LUN#2: CD/DVD sectors=358322` × 2048 = 733 843 456 B = bilkul wahi file ✓)

### 2d. Doosra VM-round: headless ISO + initrd-guard (aur ek panic jo humne khud ko sikhaya)

| kya | kyun | proof |
|---|---|---|
| `make iso PK_SERIAL=1` → `pkos-1.0-serial.iso` (release ka naya asset) | "screen hi nahi aayi" wali halat me bhi poora boot padhne layak: default entry me `console=ttyS0,115200n8` | QEMU `-display none` + `-serial file:` me GRUB menu (12 entries) + `### PK: BOOT-OK … ###` + `login: root / pk` + `pk:/root#` prompt ✓ (`pkos-vm-serial-demo.log`) |
| `scripts/mk-initrd`: **static busybox ka hard check** | is sandbox me ek baar `busybox-static` absent tha → initrd me dynamic busybox gaya → `/bin/sh: libresolv.so.2 … ` + `Kernel panic - not syncing: Attempted to kill init!` = **bilkul khali screen**. Aise me build ab chup-chaap toota ISO banane ke bajaye die karta hai (`PK_ALLOW_DYNAMIC_BUSYBOX=1` do to lib closure copy karke chale bhi deta hai) | `make doctor` me "static busybox: /bin/busybox" row ✓ |

## 2e. Reference-OS audit (Alpine / ArchISO / Fedora-live / Ubuntu-casper / TinyCore / SystemRescue / Ventoy)

Poora table: **docs/COMPARE.md**. Jo kami is comparison se nikli — sab *add* ki, kuch hataaya nahi:

| kami (real-hardware risk) | fix | proof |
|---|---|---|
| initrd me `nls_cp437`/`nls_utf8`/`msdos`/`ntfs3` nahi the (Debian ka `vfat` inhe runtime me maangta hai; `modules.dep` me ye dep nahi, isliye hamara closure bhi nahi laata) → **FAT32/exFAT pendrive partition se image boot hi nahi hoti thi** | modules initrd me add + live-modules me `kernel/fs/unicode`/`fat` | QEMU: `live base: /live/pk.sqfs from /dev/vda1 (fs=vfat)` → `BOOT-OK` ✓ |
| ek hi `mount -t <fs>` attempt → option mismatch par `EINVAL` (yahi upar wala bug chupa hua tha) | `vfat:ro,utf8`, `iocharset=utf8`, `msdos`, aur ant me **auto-detect** fallback | same test ✓ |
| live media ke liye koi retry nahi (retry sirf installed `root=` me tha) → dheeme USB3/mmc reader par "media nahi mila" | `rootdelay=`/`pk_rootdelay=` + retry loop (default 12 s) — Alpine `realroot`/casper `CASPER_TIMEOUT`/`wait=` jaisa | QA me pass ✓ |
| **Frugal boot nahi tha** (ISO file ko partition me rakh ke boot — Ubuntu `iso-scan`, TinyCore/Alpine, Ventoy ka model) | `try_iso_file()`: `pkos*.iso`/`*.iso` auto-scan + `pk_iso=<path|naam>` pin; loop+iso9660 mount | QEMU: `BOOT-OK media=/dev/loop0` ✓ |
| `/dev/mapper/*` (Ventoy dm device) scan me nahi | `list_extra_devs()` + extra live paths (`/boot/live/pk.sqfs`) + `btrfs`/`f2fs` | scan logic ✓ |
| "screen khaali" jaisa bug field me debug karna mushkil | `pk_fsdebug=1` → har mount ka asli error + device size/first-sector + insmod failures | is se hi ye bug pakda ✓ |
| admin tooling (SystemRescue/Alpine parity) | live image me `lsblk`, `findmnt`, `wipefs`, `blkdiscard` | `make iso` ✓ |
| `make usb` sirf dd karta tha | **`tools/write-usb.sh --frugal`**: MBR + FAT32 + ISO file copy (init usse loop-mount karta hai) | tool se bana image QEMU me bootable ✓ |
| QA me media layouts cover nahi | **naya stage `1b`**: FAT32-partition media + frugal ISO-file boot (4 checks) | **`QA PASS 68 checks ok`** ✓ |

## 3. Is round me jo bug pakde aur fix kiye

1. **pk-x ka jhootha success** — x-env likh dena = "session chal gaya" (weston mar bhi
   gaya ho to bhi). Ab **socket ka wait** (`$RT/run/pk-x/wayland-1` / `/tmp/.X11-unix/X0`)
   aur weston fail hone par **Xvfb fallback** (VM me yahi fallback chala ✓ proof).
2. **XDG_RUNTIME_DIR galat namespace** me export ho raha tha (`/opt/pk/run/pk-x`, host path)
   → chroot ke andar client ko socket mil hi nahi sakta tha (weston-terminal turant marta
   tha). Ab in-chroot path (`/run/pk-x`) + `PK_XDG_RUNTIME_HOST` ✓
3. **busybox `dd` me `conv=sparse` nahi** → installed system ki `pk-runtime-rw.img` kabhi
   banti hi nahi thi (silent). Fix: `mk_sparse()` (truncate, warna 1-byte seek) — ab
   installed boot par `mode=rw-image (/var/lib/pk/pk-runtime-rw.img)` ✓ QA-proved.
4. **`conv=fsync` bhi busybox dd me nahi** → pk-check ka speed test hamesha fail. Fix: alag `sync`.
5. **live image me `libgcc_s.so.1` missing** tha → `mksquashfs` "pthread_exit" par abort;
   isse selftest ka AppImage case fail ho raha tha. Fix: naya `config/live-libs.txt`
   (ldd jo nahi batata wo libs) + `mksquashfs` live image me ✓ ab `APP-APPIMAGE-OK`.
6. **overlay ka `bin/` `/bin` me jaata hai, `/usr/bin` me nahi** — `[ -x /usr/bin/pk-x ]`
   type guards chup-chaap fail (pk-check ka GUI block, pk-boot ka keymap block).
   Fix: `command -v`.
7. **SOURCE_DATE_EPOCH + `-mkfs-time`** → mksquashfs 4.6 "can't be used at the same time"
   se fatal (build hi toot raha tha). Fix: version dekh ke hi flag (4.4+ env khud honor
   karta hai) ✓
8. **live password ka random salt** payload hash ko todta tha → `SOURCE_DATE_EPOCH` ho to
   salt deterministic (`sha256("pk-live-<epoch>")`) ✓ ab squashfs/initrd byte-stable.
9. `pk-check` me disk size ganit galat (`/2048/512`), wifi iface detection (glob me
   `/wireless` suffix nahi), `--apps` rc ignore karta tha — sab fix.
10. **Sandbox workspace reset** (teesri baar): `.git/`, `rootfs/`, badi files gayab.
    Ab `tools/restore-from-iso.sh` se **ek command me restore** (ISO hi backup hai) —
    36 files wapas, `sh -n` + byte-compare se verified.

## 4. iOS / Android — kya kiya (aur imaandaar limit)

* `pk-run` ab `.ipa` **detect** karta hai (zip + `Payload/`) aur crash/hang kiye bina
  3 asli wajah + 3 raaste batata hai → `### PK: APP-IOS-DIAG-OK ###` (QA me pass).
* `pk-ios` : `why` · `doctor` · `info file.ipa` (fat/Mach-O arch + Info.plist keys) ·
  `extract` · `web <url>` (kiosk launcher, iOS-only *service* desktop app ban jaati hai) ·
  `mac-guest` (QEMU macOS + Xcode iOS Simulator recipe likhta hai) · `darling`
  (macOS binaries; **iOS nahi** — UIKit Darling me bhi nahi).
* `pk-android` : `doctor` (binderfs/ashmem/kvm/waydroid ka haal), `enable`, `install x.apk`,
  `kernel-frag` (apne kernel ke liye exact config).
* Limit (unchanged, physics+EULA): iOS app native Linux par **nahi** chal sakti. Is sandbox
  me macOS guest / Darling / binderfs kernel **test nahi** kiye (KVM nahi, 8 GB RAM nahi,
  kernel build 30-90 min). `docs/IOS-ANDROID.md` me poora hisaab.

### 4f. "GRUB ke baad display kaali" (user ka VBox report) — reproduce + fix

User ne kaha: menu theek, uske baad black screen. Pehli baar **screen ko khud capture** kiya
(QEMU `-vga std/-device vmware-svga` + monitor socket par `screendump`), naya tool
`tools/vm-shot.sh` — jo PNG + "kitne % pixels non-black hain" report karta hai:

| snapshot | non-black | screen |
|---|---|---|
| t=3 s | 7.3 % | GRUB menu ✓ |
| t=18 s | **0.2 %** | poori kaali — kernel/KMS handoff window (normal) |
| t=24/30/36 s | 6.2 % | `### PK: BOOT-OK ###` + motd + `login: root password: pk` ✓ |

Yaani QEMU/std-VGA aur QEMU/vmware-svga (VBox VMSVGA ka equivalent) dono par boot **dikh jaata hai**;
15-25 s ka kaala window expected hai. User ke case me sabse likely: (a) `--type headless` start
(their log me wahi tha) → window hi nahi, (b) 3D+VMSVGA handoff, (c) 900 MB RAM (< required 2 GB).

Additive fixes (kuch hataaya nahi):
- `etc/pk-boot.d/S08display` hook: har boot par `fb*/blank=0`, VT DPMS-off + cursor-on (raw ANSI,
  busybox me `setterm` nahi hai), laptop backlight `bl_power=0` + brightness=max, aur `/dev/tty1`
  par ek line → "blanking" vs "ataka boot" 1 second me alag. Marker `DISPLAY-OK`/`DISPLAY-NOCONSOLE`,
  option `pk_display=off`.
- Default cmdline me `consoleblank=0 vt.global_cursor_default=1`.
- GRUB me 2 nayi entries: `v` = safe graphics (`nomodeset`), `b` = nomodeset + serial.
- `pk-check` me `backlight` + `fb-blank` rows; `tools/vm-shot.sh` (screenshot harness);
  docs: `VM-TEST.md` ka naya section (VBox `controlvm screenshotpng`, 3D-off/vboxvga recipe,
  serial path) + `PENDRIVE.md` me "kya dikhega" timeline.
- QA stage 1 me 2 naye checks (`PK: DISPLAY-` marker, grub.cfg me nomodeset entry) →
  `make test` = **QA PASS 70 checks ok**.

Sandbox ne beech me `.git` ko `c2c545c` par roll-back kar diya tha (media-audit commit sirf GitHub
par tha) → `git fetch origin` + rebase se dono rounds ek saath; QA uske baad 70/70.

**Abhi unchecked:** user ki asli VirtualBox window (mere paas sirf unka headless log tha) aur real
physical GPU/UEFI machine — dono par `v`/`b` entries aur serial path hi final answer denge.

### 4g. 6 GB RAM/swap (user ki request) + swap ka footgun fix

User bola "use 6gb swap" → do kaam:
1. **Naya boot option `pk_swap=<MB>|auto|off`** (`S60tune`): installed system ya PK-PERSIST (ext4) par
   `/var/tmp/pk-swapfile` (pehle /persistence try) bana ke `swapon`; `auto` = RAM/2 (1–8 GB clamp); marker `TUNE-SWAP-OK (NM)` / `TUNE-SWAP-SKIP`.
   `/etc/default/pk` me `PK_SWAP=` default. Manual: `pk-tune swap 6144`, `pk-tune swap 0`.
2. **Bug jo isme dikha (pehle se tha):** purana `pk-tune swap` bina filesystem-check ke
   `/var/tmp` me `dd` karta tha — **live session me /var/tmp = tmpfs = RAM**, yaani "6 GB swap"
   maangne par 6 GB RAM khao jaata (aur swapon tmpfs par fail hi hota). Ab:
   `fstype_of()` (findmnt, fallback /proc/self/mounts) se sirf ext2/3/4, xfs, btrfs, f2fs accept
   hote hain; `df -Pk` se free-space check (kam ho to size khud chhoti kar deta hai, bahut kam ho
   to skip); `mb` non-numeric/64 GB+ par clamp. Live me result ab **saaf SKIP** hai, silent fail nahi.
3. QA: stage 0 ke test ISO me `pk_swap=256`; stage 1 me naya check
   `PK: TUNE-SWAP-SKIP` (live guard kaam karta hai) aur stage 3 (installed ext4) me
   `PK: TUNE-SWAP-OK` (asli swapfile + swapon) — yaani dono side prove hote hain.
4. VM settings pehle maine "6144 MB recommended" likh diya tha - **wo galat / overkill tha** (user ka matlab "6 GB swap" = *sandbox host* ka swap, taaki kaam karte waqt OOM na ho; ISO ya guest ke liye 6 GB ki zarurat nahi). Ab docs me verified numbers: base ISO 768 MB (QA default 640 MB), apps ISO 2048 MB.

### 4h. Host par 6 GB swap (user ka idea, OOM bachane ke liye) + usse jo 6 GB guest test possible hua

Host (sandbox) ke paas sirf 1984 MB RAM tha, isliye pehle 6 GB guest test atak gaya tha.
User ke kehne par host par 6 GB swapfile banaya (`dd` + `mkswap` + `swapon`) — tab:
- **apps ISO @ `-m 6144` + `pk_swap=6144`** → `VERIFY-OK`, `BOOT-OK`, `MDEV-OK`, `DISPLAY-OK (text=on)`,
  `RUNTIME-OK src=pk-runtime.sqfs`, `NET-OK (10.0.2.15)`, `CHECK-OK (7, 0 fail)`, `APP-ELF/SCRIPT-OK`,
  `APP-SANDBOX-OK`, `RUNTIME-EXEC-OK`, `APPS-OK`, `SELFTEST-OK` — 160 s me poora boot ✓
- live par `pk_swap=6144` → `TUNE-SWAP-SKIP` + reason `skip /var/tmp (fs=overlay: … swap ka matlab RAM khana hota)`
  ✓ guard sahi kaam karta hai (installed/PK-PERSIST par `TUNE-SWAP-OK` — QA stage 3 me 256 M se prove ho chuka hai)
- `scripts/run-test.sh` ka VM-RAM cap ab **RAM + SwapFree** dekhta hai (pehle sirf `MemAvailable`;
  isliye host par swap hote hue bhi QA khud 640 MB par simat jaata tha). `PK_QEMU_MEM=6144 make test`
  → bina shrink-warning ke **15/15** (stages 0,1,1b,1d) ✓
- **Clarification (user ne theek kaha):** "use 6gb swap" ka matlab *sandbox host* par swap tha taaki build/QA ke waqt OOM na ho — 6 GB ki ISO banane ka koi irada nahi tha.
  Published assets ka asli size: `pkos-1.0.iso` 88 031 232 B (84 MB), `pkos-1.0-serial.iso` 88 031 232 B, `pkos-1.0-apps.iso` 734 007 296 B (700 MB).
  6 GB guest RAM sirf ek *test config* thi (`-m 6144`); guest ke liye 2048 MB kaafi hai aur host swap sandbox ki taraf se laga, ISO me kuch nahi gaya.

**Abhi bhi unchecked:** aapki asli VirtualBox window (hamare paas sirf aapka headless log tha),
physical GPU/UEFI machine, Wi-Fi association, real `.exe` GUI, macOS/Android guest, LUKS, Secure-Boot signing.

### 4i. "6 GB ISO" wali galatfehami — sizes ka record

User ne clear kiya: 6 GB swap = **sandbox host** ka (OOM se bachne ke liye), 6 GB ISO nahi chahiye.
Verify kiya (GitHub se anonymous HEAD, `content-length`):

| asset | size |
|---|---|
| `pkos-1.0.iso` | 88 031 232 B = **84 MB** |
| `pkos-1.0-serial.iso` | 88 031 232 B = **84 MB** |
| `pkos-1.0-apps.iso` | 734 007 296 B = **700 MB** (zyada tar Debian App Runtime: apt/Wine/weston) |
| `pkos-1.0-src.tar.gz` / `.bundle` / sha256 | 170 748 / 233 377 / 693 B |

Koi 6 GB artifact kabhi bana hi nahi. Galati sirf **docs/release-body ki guidance** me thi
("VM RAM 6144 MB ideal") — wo is commit me verified numbers se badli: base ISO 768 MB
(`make test` ka default `PK_QEMU_MEM:-640`), apps ISO 2048 MB, aur `pk_swap` ka example
`auto` (6144 nahi). Chhota download chahiye to: **base ISO (84 MB)** + runtime ko pendrive ke
free partition par `pk-runtime --setup <file>` se rakho (ISO me embed karne ki zarurat nahi).

### 4j. "GRUB ke baad desktop screen par kyun nahi aata tha" — 5 layered wajahen (sab fix, sab measured)

Aapka sawaal: *live/install select karne ke baad desktop aayega ya nahi?* Live aur
install (text console + login) pehle se proven hai. **Desktop** nahi aa raha tha —
raasta saaf karne me 5 alag-alag layer ka bug nikla, ek ke baad ek test karke:

1. **Live image me GPU KMS driver the hi nahi.** `config/live-modules.txt` me sirf
   `tiny/simpledrm.ko*` + `drm_kms_helper` the, aur is Debian kernel me
   `CONFIG_DRM_SIMPLEDRM`/`CONFIG_SYSFB_SIMPLEFB` **off** hain (yaani driver na hone par
   `/dev/fb0` bhi nahi banta) -> guest me `ls /sys/class/drm` = sirf `version`,
   `/dev/dri` = *No such file or directory*. weston ko device mil hi nahi sakta tha.
   **Fix:** `vmwgfx vboxvideo qxl tiny(bochs+cirrus) virtio ast mgag200 i915 nouveau
   radeon vga16fb` ship hote hain (base ISO 88,031,232 -> 91,813,888 B, ~+3.6 MB).
   Debian me file ka naam `tiny/bochs.ko.xz` hai (`bochs-drm.ko` nahi) — purana pattern
   isliye 0 files match kar raha tha.
2. **Display status jhooth bata raha tha:** `S08display` hook `S15mdev` se *pehle* chalta
   hai, to `fb=0 drm=0` hamesha — "display mar gaya" jaisa galat signal.
   **Fix:** naya `etc/pk-boot.d/S99zdisplay` — display-class PCI device ho to drivers
   explicitly `modprobe` karta hai, phir **final** `fb=/drm=/driver=` se
   `/run/pk/display.txt` + motd line update karta hai, aur marker maarta hai:
   `### PK: DISPLAY-KMS (drm=1 driver=bochs-drm fb=1) ###` / `### PK: DISPLAY-TEXTONLY ...###`.
3. **`exec` ne poora fallback chain mara hua tha:** `pk-x` me
   `exec weston A || exec weston B || ...` tha — `exec` shell ko replace kar deta hai,
   isliye *pehla fail hone ke baad doosra attempt kabhi chala hi nahi*, aur har attempt
   par `2>/dev/null` hone se error dikhta bhi nahi tha (file 0 bytes, koi clue nahi).
   **Fix:** chain se `exec` hataya, errors ab `/run/pk/x-weston.log` me rehte hain aur
   aakhri lines `### PK: DESKTOP-WESTON-LOG ... ###` marker me bhi aati hain.
4. **weston 10 ko VT chahiye:** ab log me asli reason aaya —
   `logind: cannot find systemd session for uid: 0` -> `could not get launcher fd from env`
   -> `<stdin> not a vt` / `if running weston from ssh, use --tty to specify a tty`
   -> `fatal: drm backend should be run using weston-launch binary, or your system should
   provide the logind D-Bus API`. Hamare live me logind nahi hai (busybox + mdev).
   **Fix:** weston ko `--tty=/dev/tty1` + `</dev/tty1` ke saath chalaya (direct launcher),
   `LIBSEAT_BACKEND=builtin`. Result log me: `Trying direct launcher...` /
   `using /dev/dri/card0` / `DRM: supports atomic modesetting` ✓
5. **Runtime me software GL nahi tha:** Debian ka weston 10 sirf `gl-renderer.so`
   banata hai (`pixman-renderer.so` build me hi nahi), aur hamare App Runtime me
   `/usr/lib/dri` tha hi nahi -> `MESA-LOADER: failed to open bochs-drm:
   /usr/lib/dri/bochs-drm_dri.so: No such file or directory` -> GL context nahi -> weston fatal.
   **Fix:** desktop runtime me `libgl1-mesa-dri,libegl-mesa0` (llvmpipe = software GL) +
   DRI na mile to `LIBGL_ALWAYS_SOFTWARE=1`. Ye "har PC/desktop hardware par chale" ke
   liye bhi sahi raasta hai: jis GPU ka kernel driver ke paas DRI nahi, wahan bhi weston
   ab paint karta hai (slow but working).
   (Saath me `fonts-dejavu-core,adwaita-icon-theme` — inke bina weston-terminal/xterm
   khulte to the par text render nahi hota tha, aur `could not load cursor` warn aata tha.)

Is dauran jo *aur* product-level bugs raaste me mile, wo bhi fix kiye (kuch hataaya nahi):
- `scripts/make-runtime`: debootstrap/chroot `$SUIT/etc` ko root-owned chhod dete hain ->
  bina-root user ke liye `make runtime` / `make runtime-desktop` EACCES se **fail** (2 baar
  reproduce hua). Ab release file privileged copy se likhi jaati hai + tree wapas chown.
- `scripts/mk-iso`: chhote `/tmp` (1 GB tmpfs wale containers / live-USB build) par
  `grub-mkrescue: No space left on device` se ISO build toot-ti thi -> ab `TMPDIR=$WORK/tmp`.
- Makefile: `KERNEL_CMDLINE`/`init/grub.cfg`/`config/live.conf` badalne par bhi purani ISO
  re-use ho jaati thi (stale image ship) -> `$(ISO)` ab in dono par depend karta hai.
- `mk-iso` me `sed "s|@ARGS@|$args|g"` — args me `|`/`&`/`\` aate hi build toot-ta tha
  (e.g. `pk_runtime=/dev/sdb1` jaise args ke saath) -> ab escape hota hai.
- **GRUB config me `;` command separator hai** -> kernel args me `;` daalte hi args kat
  jaate hain (ye humein debug ke dauran Khaas dafa dhokha de gaya). Naye `pk_run=` option
  me isliye `!` separator hai (space = `+`).
- **Naya boot option `pk_run=<cmd>`**: boot ke baad ek command ka output console par
  (poora `/run/pk/pk_run.out` me) — "screen par desktop kyun nahi aaya" type sawaalon ke
  liye, bina keyboard/mouse ke. Example: `pk_run=cat+/run/pk/x-weston.log`
- `scripts/run-test.sh`: 2 nayi QA checks (73 -> 75): `PK: DISPLAY-KMS` + `driver=bochs`,
  taaki koi future build GPU drivers bhool jaye to turant pakda jaaye.
- `docs/VM-TEST.md` me naya section **#2b "Graphics device ka chunav"** (QEMU `-vga vmware`
  par kernel `probe with driver vmwgfx failed with error -38` deta hai — QEMU sirf SVGA v2
  emulate karta hai; `-vga std`/`-vga virtio` use karo. VirtualBox `vmsvga`/`vboxvga` dono
  theek), `docs/TROUBLE.md` me **#4b** marker-table, `docs/BUILD.md` me chhote-/tmp note.

### 4k. Desktop ka abhi ka sach (is round ka end-state, measured)

`make test` ab **75/75 PASS** (naye `PK: DISPLAY-KMS` + `driver=bochs` checks ke saath),
aur QEMU me live boot par guest ke andar:

- `/dev/dri/card0` milta hai, `DISPLAY-KMS (drm=1 driver=bochs-drm fb=1)` ✅
- `DESKTOP-OK (wayland-1)` + `TUNE-FG-OK (weston, 3)` -> **weston sach me chalu ho jaata
  hai** (pehle `exec`-bug + `2>/dev/null` ki wajah se session chup-chaap Xvfb/headless par
  gir jaata tha; `DESKTOP-WESTON-LOG` marker se ab wo sab saaf dikhta hai)
- weston ka log: `Trying direct launcher... / using /dev/dri/card0 / DRM: supports atomic
  modesetting` -> device + GL path (llvmpipe) dono ready
- Par **screen par abhi bhi text console hi dikhta hai** (1280x800 me, `pk:/root#` tak):
  weston compositor to chal raha hai, par hamare live system me **logind/seatd session
  nahi** hai, isliye wo visible VT (tty1) ko graphics mode me nahi le jaata. `--tty=/dev/tty1`
  + `</dev/tty1` aur `seatd-launch` dono try kiye — weston chalta hai par fbcon screen par
  rehta hai. Ye ek *session-manager* ka kaam hai; baaki sab layer ab theek hain.

Is state me user ke liye practical raaste (sab tested/tuned):
1. **GUI chahiye to `pk-desktop vnc 5900`** -> Xvfb + VNC; apne PC se `10.0.2.15:5900`
   (QEMU) / guest-IP (VBox NAT) se dekho. Apps, terminal, sab chalta hai.
2. **Installed system** me (disk par `pk-install`) jab `systemd-logind` aa jaayega,
   `weston` user session ke roop me chalani chahiye — *ye abhi test nahi hua* (sandbox me
   systemd-based install boot nahi karate), isliye promise nahi kar raha.
3. `make iso-full`/bade runtime me `seatd` service + `logind`-compatible session lane ka
   kaam bacha hai (weston ko VT dilaane ka standard tareeka). Chahoge to agla round yehi karunga.

### 4m. Session manager + users + I/O devices (is round ka kaam)

User bola: *"desktop to aana hi chahiye aur sare input/output device bhi kaam karni
chahiye, seatd session bhi banana chahiye aur user bhi add/remove hone chahiye"*.
Kya-kya joda (sab additive; purana fallback chain intact):

- **`pk-seatd` + `S55seatd` hook**: seatd (30 KB, systemd-free session manager) ko
  **App Runtime ke andar se** chalate hain -> base ISO ka size nahi badha. Socket
  runtime ke `/run/seatd.sock` par banta hai, group `seat` (gid 990, 0660). Weston
  `LIBSEAT_BACKEND=seatd` se VT + `/dev/dri` + `/dev/input` isi se leta hai.
  Markers: `SEATD-OK (socket=…)` / `SEATD-SKIP (no runtime|seatd)` / `SEATD-FAIL`.
- **weston ab *visible* VT par**: `pk-x` `/sys/devices/virtual/tty/tty0/active` padhkar
  `XDG_VTNR=<wahi>` + `--tty=/dev/tty<same> </dev/tty<same>` deta hai, aur attempt ke baad
  `DESKTOP-VT (want=ttyX active=ttyY)` / zaroorat padne par `DESKTOP-VTMISMATCH` maarta hai
  + `/run/pk/x-how` me detail. (Pichhli baar weston tty7 le raha tha -> screen par text.)
- **I/O device modules** live me: `sound/core`, `snd-hda-intel`, `snd-ac97`,
  `snd-usb-audio`, bluetooth (net+drivers), `uvc` webcam, hwmon (sensors),
  power_supply (laptop battery), backlight, thunderbolt, usb/typec, usb/misc.
- **Device permissions**: naya `/etc/mdev.conf` -> `/dev/snd/*`=audio, `/dev/input/event*`=input,
  `/dev/dri/card*`=video (0660), `/dev/ttyUSB*`=dialout, `/dev/video*`=video, block devices
  root-only (disk group 0660), aur **har** rule par `@/etc/mdev/hotplug.sh` (busybox mdev
  pehla match leta hai -> hotplug modprobe na chhoot jaaye, ye isliye har line me repeat kiya).
- **`pk-user`** (naya command): `list / info / add / del / passwd / autologin / doctor`.
  `add` me busybox `adduser -D` + har group ke liye `addgroup user grp` (busybox ke `-G` par
  bharosa nahi), home + /etc/skel + 700, `--password=` -> `chpasswd`, `--admin` -> `wheel`
  (+ `/etc/sudoers.d/90-<u>` agar sudo ho). Naye user ko default groups: `users,audio,input,
  video,render,dialout,lp` + `seat` -> **device access = user access** (bina root ke sound/keyboard/GPU).
  `del` `--home`/`--force`, process pehle `pkill -u`, aur `deluser` fail ho to manual
  /etc edit (backup `/etc/passwd.pk-bak`) + autologin cleanup. `pk-check --users` poora
  round-trip (add -> `su -m` -> del) khud chalata hai.
- **Pre-created `pk` user** (uid 1000) ko device groups diye; naya `S12users` hook har boot
  groups/homes ensure karta hai (missing home -> login fail hota tha) + marker `USERS-OK`.
- **`pk_user=<name> [+ pk_userpw=<pw>]`** boot option: live me user banao + tty1 autologin;
  `pk-console` ab `/run/pk/autologin` / `/etc/pk-console.conf` dekhkar **us user ke tor par**
  shell khola (`su -m`), warna root (live) ya getty (installed). `pk-user autologin off` wapas.
- Runtime (desktop variant) me: `seatd`, `alsa-utils` (amixer/aplay), `xwayland`
  (weston ke andar xterm jaise X apps), pehle se `weston xterm xvfb mesa-utils wine`
  + is round me `libgl1-mesa-dri`(llvmpipe), `fonts-dejavu-core`, `adwaita-icon-theme`.
- QA: `USERS-OK`, `MDEV-OK`, `SEATD-OK`, `DESKTOP-VT`, `DESKTOP-WESTON-LOG` checks +
  ek **negative** check (`DESKTOP-VTMISMATCH` aaya to test FAIL) -> ab 80 checks.

### 4n. Ye round guest me kya-kya *prove* hua (apps ISO, QEMU q35, virtio-gpu+EDID / -vga std)

| Check | Measured result |
|---|---|
| seatd session manager | `### PK: SEATD-OK (socket=/run/seatd.sock in runtime, pid=1347) ###` + `pk-seatd status: RUNNING`, socket `srw-rw---- root seat` ✅ |
| KMS device | `DISPLAY-KMS (drm=1 driver=virtio-pci fb=1)` (aur `-vga std` par `driver=bochs-drm`) ✅ |
| weston + visible VT | `DESKTOP-VT (want=tty1 active=tty1 seatd=1)`, **koi `DESKTOP-VTMISMATCH` nahi**, `DESKTOP-OK (wayland-1)`, `TUNE-FG-OK (weston, 5)` (weston + keyboard + desktop-shell + **weston-terminal**) ✅ |
| Users | `USER-ADD-OK (bob)`, `USER-AUTOLOGIN (bob)`, `USERS-OK (… autologin=…)`; screen par `logged in as: bob (uid 1001 …)` ✅ |
| User ka device access | `su -m bob -c id` -> `groups=…,44(video),63(audio),100(users),108(input),160(render),990(seat)` ✅ |
| User delete | `pk-user del bob --home` -> passwd/shadow/group/home sab saaf ✅ |
| Device perms (nodes) | `/dev/input/event0 = crw-rw---- root input` (mdev.conf) + `pk-devperms: /dev/dri/card* -> :video (660), /dev/input/event* -> :input (660), /dev/tty[0-9]* -> :tty (620), /dev/ttyS* -> :dialout (660)` ✅ |
| Audio | `snd-hda-intel` load hua, `/dev/snd/timer` bana, par **pcm node nahi** -> is QEMU build me `-audiodev` backend hi nahi (`-device hda-duplex: no default audio driver available`), yaani emulated codec hi nahi. Real PC/VBox par test bacha hai (modules + perms side verify ho chuka) ⚠ |
| Screenshot | `pk-desktop shot` in-tree + `weston --debug` laga; `timeout 25` wrap bhi (pehle `weston-screenshooter` static desktop par frame ka wait karta tha -> QA stage-8 hang). pk-check me row warn rahta hai, QA use hard-fail nahi karta; **PNG ka pixel proof aap machine par**: `pk-desktop shot /root/desktop.png` ⚠ |
| QA (is tree par, final) | `make test` = **QA PASS 77 checks ok** (8 stages: live, FAT32/frugal media, install, installed-boot, toram, UEFI, persistence+net+ssh, apps, kit+GUI) aur `make gui-test` = **QA PASS 24 checks ok** — usme `seatd session manager chalu`, `weston ne active VT liya`, `no VTMISMATCH`, `GUI-APP-OK (weston-terminal)`, `pk-check: koi FAIL nahi`, install + installed-boot sab ✅ |

Is round me jo *aur* latent bugs gare (sab fix):
- `pk-boot` me `say()` define hi nahi tha -> 7 jagah `pk-boot: line N: say: not found` (log ka
  aadha hissa gubaar). Ab alias hai.
- Live image me hamari files `/bin` me hoti hain (merged-usr assumption galat): `S55seatd`
  `[ -x /usr/bin/pk-seatd ]` dekh kar **chup-chaap skip** ho raha tha, aur `pk-check` ka shot
  row bhi isi wajah se nahi chala. Ab sab `command -v` se ✅
- `pk-boot` aur `pk-check --gui` dono `pk-x start` karte the -> doosra instance weston ke
  `wayland-1.lock` par "unable to lock" de kar Xvfb par gir jaata tha. Ab `pk-x start`
  idempotent (session zinda ho to wahi reuse) + stale `.lock` cleanup.
- `pk-chroot` non-root se bura fail karta tha (beech me `Permission denied` ki chaar linein);
  ab pehle hi saaf message + exit 65.
- Autologin serial/recovery console par bhi lag raha tha (bob ke saath root logs padhne ko
  taras jaate); ab autologin sirf physical console par, `ttyS*/hvc*` root hi rehta hai.
- `pk-seatd` ab runtime-mount ka 15s wait karta hai (hook-order fragility khatam).

Ab bhi khula: real-hardware audio/wifi, `amdgpu/xe` (firmware), `weston-screenshooter` ka
pixel-proof aapki taraf se, aur `pk-desktop` ke *andar* normal-user Wayland session (abhi
desktop root session hai; user ke paas device access hai par runtime chroot root-only hai).

## 5. Aapke PC pe ab kya karna hai (emulator → pendrive → install)

```sh
sudo apt-get install -y build-essential busybox-static cpio squashfs-tools xorriso mtools \
  grub-pc-bin grub-efi-amd64-bin grub2-common dosfstools parted e2fsprogs util-linux kmod \
  linux-image-amd64 dropbear ovmf qemu-system-x86 kbd
sudo apt-get install -y debootstrap                      # App Runtime ke liye

cd pkos
make doctor && make iso && make test        # ~15-18 min, 64 checks
sudo make runtime-desktop && make apps-iso # GUI+wine wala runtime, phun 700 MiB ISO
make kit                                    # iso + apps-iso + manifests + bundle (ek saath)

lsblk && sudo dd if=build/pkos-apps.iso of=/dev/sdX bs=4M status=progress oflag=sync
tools/verify-usb.sh /dev/sdX build/manifest-apps.txt     # host se: sahi likha?
```

Pendrive se boot (Secure Boot OFF) → menu me **`k`** = hardware check, **`g`** = desktop.
Live shell me:

```sh
pk-check --save        # report: /run/pk/check.txt  (FAIL 0 hona chahiye)
pk-run --selftest      # apps battery → ### PK: APPS-OK ###
pk-desktop             # weston/Xvfb session + terminal
pk-get install -y htop # (net: pk_net=dhcp) — apt andar se
pk-install --target=auto --user=ramesh --user-password=SomePw   # permanent
```

Fail ho to **bhej dena**: `/run/pk/check.txt`, `dmesg | grep PK`, `build/manifest.txt`.

## 6. Abhi bhi nahi hua (taaki surprise na ho)

- **Real hardware pe boot** — ye sab QEMU me prove hua hai; terahz GPU/KMS/USB stick par
  test aapke haath me hai (isliye `pk-check` bana).
- **Wi-Fi association** — `pk-wifi` likha hai, par yahan wireless hardware nahi, to
  `status` ke alawa kuch test nahi hua (documented experimental).
- **Android**: binderfs wala kernel build + Waydroid end-to-end **not tested** here.
- **macOS guest / Xcode Simulator / Darling**: helper + docs ✓, par asli boot test nahi (license + KVM + RAM chahiye).
- **GUI apps ka asli frame test**: xterm/xdpyinfo round-trip ✓, par weston par
  firefox-chalao-aur-screenshot type ka visual test nahi; `/dev/dri` wale real GPU par hi hoga.
- **LUKS encrypted install** nahi (initramfs me cryptsetup chahiye — alag kaam).
- **Secure Boot signing** nahi (unsigned GRUB; BIOS me OFF).
- **Non-root user ka sudoers**: group me daalte hain, par runtime/`sudoers` file me
  NOPASSWD entry nahi (busybox `sudo` package runtime me aayega to `pk-get install -y sudo`).
- Console keymaps: builder par Debian `kbd` me `/usr/share/keymaps` nahi hai → `pk-keymap`
  ka console part skip (GUI `setxkbmap` chalta hai). Jo distro kmaps degi, wo auto-copy ho jaate hain.
- **`pk-vm` se guest boot** abhi tak kabhi chala ke nahi dekha (helper + docs only).
- Git history (reset se pehle ke 12 commits) wapas nahi aa sakti; ab 3 clean commits.

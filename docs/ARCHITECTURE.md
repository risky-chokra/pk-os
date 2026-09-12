# pk's OS · ARCHITECTURE — modern desktop-OS requirements vs ye OS kya karta hai

Base = **Linux kernel (host distro ka 6.12) + busybox live userland + Debian App Runtime**.
Is page me har requirement ke saamne likha hai: *kaun deliver karta hai*, *verify kaise karein*,
aur jo sach me nahi hai wo 🚫 flagged hai (status labels neeche).

```
✅ = already working (kernel/our stack), verify command ke saath
🟩 = is round me add hua + QEMU QA me verified
🟨 = aadha hai (kya hai / kya missing, dono likhe hain)
🚫 = is design/hardware par possible nahi (reason ke saath) — baaki round ka kaam
```

Ek hi command se zyadatar cheezein dikha jaati hain (live system me):

```sh
pk-tune report      # cpu/topology/governor+EPP/sched/preempt/IO/mem/ipc/security/tpm/cgroup
pk-check --save     # + hardware, net, USB speed, display, runtime, apps, SecureBoot
```

---

## 1. Process / thread / CPU scheduling

| # | Requirement | Status | Kaise (is OS me) | Verify |
|---|---|---|---|---|
| 1.1 | SMP (multi-core distribution) | ✅ | Linux kernel CFS + `CONFIG_SMP=y` (Debian 6.12); hamara init/koi affinity nahi baandhta, isliye saare cores use hote hain | `nproc`, `pk-tune report` ka `cpu` row |
| 1.2 | Preemptive multitasking / time-slicing | ✅ | kernel CFS + `CONFIG_PREEMPT_DYNAMIC` (RT/AI flags ke saath Debian kernel); rogue thread CPU nahi hogs karta | `pk-tune report` → `preempt`, `sched` rows; `top` |
| 1.3 | Interactive foreground prioritization | 🟩 | **`pk-tune desktop`** → cgroup v2 `pk.slice/apps` me `cpu.weight=200`, daemons `bg` me `20`, `sched_autogroup_enabled=1`, `EPP=balance_performance`. `pk-desktop start` compositor ko aur `pk-desktop app <x>` client ko **apps slice** me daalta hai; `pk-tune fg <pid|name>` / `bg` manually | `pk-tune desktop`, phir `cat /sys/fs/cgroup/pk.slice/apps/cpu.weight`; `pk-desktop app htop` ke baad `pidof htop` ka cgroup |
| 1.4 | Heterogeneous (P/E core) awareness | 🟩 + 🟨 | **`pk-tune hybrid`** `/sys/.../cpuN/cpu_capacity` padhkar big(≥900)/little(≤700) baanta hai, `cpuset.cpus` se daemons ko little cores par, apps ko big par daalta hai. Scheduler-level EAS (energy model, `CONFIG_ENERGY_MODEL`) Debian kernel me desktop x86 ke liye enable nahi → deep integration 🚫 (kernel rebuild + energy model required) | `pk-tune hybrid` → marker `TUNE-HYBRID-OK (big=… little=…)`; VM me `uniform` aayega (capacity file nahi) — ye expected hai |

## 2. Graphics / window management

| # | Requirement | Status | Kaise | Verify |
|---|---|---|---|---|
| 2.1 | Compositing window manager | ✅ (desktop runtime me) | **weston** (Wayland compositor: har surface apna GL buffer, single flip → no tearing) — `make runtime-desktop`/apps ISO me built-in; base ISO me deliberately nahi (size) | `pk-desktop` → `### PK: DESKTOP-OK ###`; `pk-check --gui` → `GUI-XCLIENT-OK`, `GUI-APP-OK` (QA stage 8 me verified ✓) |
| 2.2 | Low-latency display server + modern GPU APIs | 🟨 | weston/DRM-KMS path (vblank-driven), Mesa OpenGL/Vulkan runtime me install ho sakte hain (`pk-get install -y mesa-vulkan-drivers libgl1`); **DirectX 12 / Metal 🚫** (Apple/MS ke APIs hain — Vulkan hi hamara route, DX12 chahiye to DXVK/Wine ke through) | `pk-chroot vulkaninfo --summary` (install ke baad), `weston-info` me `wl_compositor` |
| 2.3 | Dynamic High-DPI + multi-monitor topology | 🟩 | **`pk-desktop outputs`** (`/sys/class/drm/card*-*/` se connected + modes), **`pk-desktop scale 2 [OUTPUT]`**, `mode`, `transform`, `arrange`, `restart` → `weston.ini` runtime me likhta hai + session restart; reboot/logout ki zaroorat nahi | `pk-desktop outputs`; `pk-desktop scale 2 HDMI-A-1 && pk-desktop restart && pk-desktop ini` |

## 3. Memory & storage

| # | Requirement | Status | Kaise | Verify |
|---|---|---|---|---|
| 3.1 | Virtual memory + demand paging | ✅ + 🟩 | MMU + per-process address space + swap-on-demand: live image me default swap nahi hota (RAM me chalta hai) — **`pk-tune swap [MB]`** installed/persist fs par swapfile bana ke `swapon` karta hai (holes-free `dd` se, kyunki swapfile sparse nahi ho sakta) | `pk-tune swap 2048` → `TUNE-SWAP-OK`; `awk '/SwapTotal/' /proc/meminfo` |
| 3.2 | Memory protection / boundary enforcement | ✅ | kernel: `ASLR=2`, NX/XD, `seccomp`+`SECCOMP_FILTER`, yama `ptrace_scope`, per-process页 tables; `pk-run --sandbox` iske upar namespace isolation deta hai. 🚫 "segfault khatam" — wo memory-safe *language/runtime* ka maamla hai (Rust/Go/Ada), kernel feature nahi; kernel khud segfault se bachata hai, app bug se nahi | `pk-tune report` → `security` row (`aslr=2 … 0/17 vulnerable`) |
| 3.3 | Journaling / log-structured FS | ✅ | installer `mkfs.ext4` chalata hai → **journal (jbd2)** default on; live root = squashfs (immutable) + overlayfs upper (ext4 on persist partition = journaled). Read support: ntfs3, exfat, xfs, btrfs, f2fs, udf, isofs (live modules me) — Windows USB/HD padh sakte ho. `F2FS`/log-structured ✅ read | QA stage 2 me host-side `dumpe2fs -h` check (neeche note); live me `mount \| grep overlay` |
| 3.4 | Direct I/O (DirectStorage-jaisa) | 🟨 | `O_DIRECT` ✅, `io_uring` ✅ (kernel 6.12; `pk-tune ipc` status dikhata hai + enable karta hai), `read_ahead_kb`/`max_sectors_kb` tuning `pk-tune io` me. 🚫 GPU-initiated NVMe P2P (DirectStorage/GDN) desktop GPU vendors ke userspace stack ke bina nahi — Linux par ye abhi vendor-specific (only some NVIDIA/AMD proprietary paths) | `pk-tune report` → `io` + `ipc` rows; `dd iflag=direct` test |

## 4. Hardware & peripherals

| # | Requirement | Status | Kaise | Verify |
|---|---|---|---|---|
| 4.1 | HAL | ✅ | Linux kernel ka driver model (subsystems + sysfs) + hamara curated module set (`config/live-modules.txt`, 991 modules) initramfs ke 44 boot-modules ke saath | `pk-info`, `ls /lib/modules | wc -l`, `pk-check` ka `dmesg` row |
| 4.2 | Dynamic driver management (Plug & Play) | 🟩 | **`S15mdev` hook**: `mdev -s` (coldplug, /dev nodes) + **`busybox uevent` netlink listener** jo har uevent par `mdev` chalata hai, aur `/etc/mdev.conf` ke `@/etc/mdev/hotplug.sh` se `modprobe -q $MODALIAS` (NIC/USB-WiFi/storage/input aate hi driver load). `/proc/sys/kernel/hotplug` helper interface par bharosa nahi (modern kernel) isliye netlink wala raasta. Band: `pk_mdev=off` | boot marker `### PK: MDEV-OK (uevent listener + coldplug, rc=0) ###` (VM me verified ✓); `pk-tune report` → `hotplug` row; dongle plug karke `dmesg \| tail` |
| 4.3 | Async non-blocking I/O | ✅ | kernel (io_uring/epoll/poll + async block layer) — hamare boot hooks background me chalte hain (`S50runtime` async, `pk-net` background) taaki boot block na ho | `pk-check` (hooks ke markers boot ke saath aate hain), app me `epoll`/`io_uring` use karo |

## 5. Security & access control

| # | Requirement | Status | Kaise | Verify |
|---|---|---|---|---|
| 5.1 | DAC / RBAC + ACLs | 🟨 | DAC ✅ (Unix perms + `setfacl`/`getfacl` live image me, `FS_POSIX_ACL` ext4 default, tmpfs ACL kernel 6.6+). RBAC (SELinux/AppArmor policy engine) 🚫 live image me nahi — Debian runtime me `apparmor` package install karke *guest* policy chala sakte ho par hamare squashfs+overlay boot me policy load ka test nahi hua | `setfacl -m u:1000:rwx /mnt/persist/x && getfacl x` |
| 5.2 | VBS (hypervisor-isolated secrets) | 🚫 + 🟨 alternative | OS khud apne aap ko VBS me nahi daal sakta — type-1 hypervisor neeche chahiye. Jo hamare paas hai: (a) `CONFIG_KVM` se pk's OS **doosre OS ko isolate** kar sakta hai (`pk-vm`) — untrusted app ko VM me daalo; (b) squashfs root immutable + `pk_verify` payload-hash check (neeche). Real VBS/HVCI = Hyper-V feature; Linux equivalent = `swiotlb`+confidential computing (SEV/TDX) — hardware + kernel config mangta hai, abhi not done | `ls /dev/kvm` (ho to), `pk-vm new untrusted --size=8G` |
| 5.3 | Application sandboxing / containerization | 🟩 | **`pk-run --sandbox <app>`**: `unshare` se user+mount+pid+ipc+**net** namespaces, `/root` `/home` `/mnt/persist` `/run/pk` par tmpfs (user data app se chhup jaata hai), `/` read-only remount try; kernel user-ns na de to honest `APP-SANDBOX-UNAVAIL` + app phir bhi chalta hai. Extra: poora App Runtime hi ek chroot container hai (`/opt/pk`) with overlay upper | QA selftest marker `APP-SANDBOX-OK` ✓ (stage 7 me verify: sandbox ke andar `/root` dikhta hi nahi) |
| 3.2b | DHCP ka `default.script` exec-bit | ✅ fixed | `udhcpc` script ko exec karta hai; git me 644 mode aane par lease milne ke bawajood IP configure nahi hota tha (`NET-FAIL`) — ab `build-rootfs` stage karte waqt `usr/share/udhcpc/default.script` ko 755 karta hai + index me bhi +x | VM me: `### PK: NET-OK (10.0.2.15) ###` ✓ |
| 5.4 | Cryptographic Secure Boot / root of trust | 🟩 partial | **`pk_verify=1`**: `mk-iso` `/live/pk.sqfs.sha256` + `/live/pk-runtime.sqfs.sha256` sidecar likhta hai, init boot par hash verify karta hai → `### PK: VERIFY-OK ###` / `VERIFY-FAIL` (aur `pk_verify=require` par boot **rok** deta hai). Ye *measured/integrity* hai, *signed* nahi. 🚫 real Secure Boot: signed shim/GRUB/kernel (Microsoft UEFI CA) + TPM2 policy/PCRs — sbctl/MOK enrollment ka round alag hai; TPM bina device ke test bhi nahi ho sakta | boot marker (stage 1 QA me `VERIFY-OK` assert hota hai ✓); `sha256sum -c` of ISO; `pk-tune report` → `tpm` row |

## 6. App lifecycle & compatibility

| # | Requirement | Status | Kaise | Verify |
|---|---|---|---|---|
| 6.1 | Persistent background execution (desktop-style) | ✅ | koi mobile-jaisa freeze/suspend nahi; minimized apps chalte rehte hain (init → busybox `init` + getty, no session manager jo freeze kare). Control ke liye: `pk-tune bg <name>` (weight 20, nice +10, low IO) — kill/suspend nahi, bas share kam | `pk-tune bg htop`, phir `cat /proc/<pid>/cgroup` |
| 6.2 | Dynamic binary translation + hypervisors | 🟩 + 🚫 | **Linux foreign arch**: `pk-binfmt register` → binfmt_misc handlers (`pk-aarch64/pk-arm/pk-riscv64/pk-ppc64le/pk-s390x`) pointing to runtime ke `qemu-<arch>-static` (`pk-get install -y qemu-user-static`); `pk-run` khud e_machine (offset 18) padhkar arm64/riscv64 ELF ko qemu-user par bhejta hai — binfmt registered ho to kernel khud karta hai. **Windows**: Wine (`pk-run Setup.exe/.msi`) ✅ (QA me real wine-8.0 dispatch). **Hypervisor**: `pk-vm` (qemu guest helper) 🟨 likha hai, actual guest boot test nahi hua. 🚫 **macOS/iOS Mach-O**: Rosetta-2-jaisa kuch Linux par nahi — Darwin syscalls + closed UIKit/SwiftUI; route sirf macOS guest + Xcode Simulator (`pk-ios mac-guest`) ya Darling (macOS binaries only) | `pk-binfmt status`, `pk-run ./arm64app` → `APP-ARCH-OK`; QA me `ARCH-DISPATCH-OK` ✓; `pk-run --info file` |

## 7. Networking & IPC

| # | Requirement | Status | Kaise | Verify |
|---|---|---|---|---|
| 7.1 | High-throughput kernel network stack | ✅ + 🟨 | kernel stack (IPv4/IPv6, GSO/TSO/LRO offloads, multi-queue virtio-net/igb/igc/r8169/bnxt/atlx + USB-Ethernet r8152/ax88179/asix/lan78xx/smsc75xx hamare modules me). **`pk-tune net`**: rmem/wmem 16 MiB, tcp_rmem/wmem, `fq` qdisc, **BBR** (milte hi), TCP_FASTOPEN, jumbo MTU try. Wi-Fi: `pk-wifi` (status/scan/connect) 🟨 — `wpa_supplicant` runtime me (`pk-get install -y wpasupplicant iw`), association is sandbox me test nahi hua (wireless NIC nahi); Wi-Fi 7/5G/Bluetooth LE driver support = kernel version + firmware 🚫 guaranteed nahi | `pk-check` ka `net`/`dns`/`wifi` row, `pk-tune report` → `ipc`, `dmesg | grep -i link` |
| 7.2 | Low-overhead IPC | ✅ | kernel: unix sockets, `shmget`/POSIX shm (**`/dev/shm`** tmpfs, `pk-tune ipc` remount+size), POSIX **mqueue**, eventfd/timerfd/signalfd, pipes, `futex`, `io_uring` (registered fds), `sendfile`/`splice`. App Runtime ke andar bhi wahi host objects visible hain (`pk-chroot` /dev, /tmp, `/tmp/.X11-unix` bind karta hai) → X11 clients exactly isi se chalte hain | `pk-tune ipc` → `mqueue mounted`, `io_uring` status; `ls -l /dev/shm` inside `pk-shell` |

---

## 8. Application support matrix (aapki "sabhi apps direct" baat)

| platform | kya chalta hai | kaise | status |
|---|---|---|---|
| Linux native | x86_64/i386 ELF, scripts, `.deb`, `.rpm`, AppImage, `.jar` | kernel + `pk-run` dispatcher + `pk-get`/apt (runtime) | ✅ QA-proved (ELF/script/.deb/AppImage/jar/rpm markers) |
| Linux foreign arch | arm64/arm/riscv64/ppc64le/s390x ELF | `qemu-user` + binfmt_misc (`pk-binfmt`) | 🟩 dispatch QA-proved; asli arm64 binary ka run = runtime me `qemu-user-static` install ke baad (aapke PC pe ek command) |
| Windows | `.exe`, `.msi`, DLL-based apps | Wine 8 inside App Runtime (`pk-run Setup.exe`) | 🟨 dispatch + `wine --version` real ✅; **asli Windows app ka GUI run** mere sandbox me test nahi (GPU/display) |
| Android | `.apk` | Waydroid/binderfs — `pk-android doctor` blocker dikhata hai; guest (Android-x86) `pk-vm` | 🚫 native abhi nahi (kernel me `CONFIG_ANDROID_BINDERFS` + GSI image chahiye) |
| macOS / iOS | `.app`/Mach-O, `.ipa` | `pk-ios info/web/mac-guest/darling`; asli runtime sirf macOS guest + Xcode Simulator me | 🚫 native impossible (Mach-O/XNU + closed UIKit); honest diagnostic + routes ✅ QA-proved |
| Web/PWA | kuch bhi URL-based | `pk-ios web <url>` kiosk launcher (browser runtime me) | 🟩 |

## 9. Is round ke baad ka roadmap (jo abhi khali hai)

1. **Secure Boot signing**: `sbctl` se own PK/KEK/db + signed shim, ya MOK enrollment flow; ISO me `--sbat`. (Iske bina BIOS me Secure Boot OFF karna padta hai — documented.)
2. **TPM2 measured boot + LUKS**: initramfs me `cryptsetup` + `systemd-pcrlock`-jaisa policy nahi; chaho to `pk-install --luks` (initrd me `dm-crypt` + key-in-TPM) ka poora round.
3. **VBS-alternative硬化**: `pk-vm` se "app-in-VM" flow (untrusted app ke liye ephemeral VM) — helper hai, polish + test baaki.
4. **Real Windows-app test** desktop ISO pe (GPU + Wine + `wine32` multiarch) aur macOS guest (Xcode Simulator) — test-bench chahiye.
5. **Android**: apna kernel (`pk-android kernel-frag`) + Waydroid GSI → `.apk` direct.
6. **RBAC/audit**: runtime me `apparmor` + hamare `/etc/apparmor.d` profile for `pk-run` apps; auditd.
7. **EAS/heterogeneous scheduler integration**: `CONFIG_ENERGY_MODEL` + `pd` affinity — custom kernel build wala round (`make kernel`).
8. **`pk-desktop` ko full session banane ka**: launcher bar, `weston-desktop-launcher`, autostart of `pk-check` result widget — abhi session + terminal + welcome hai.

> Note: kuch items ("segfault khatam", "DirectX 12 on Linux", "iOS apps native") category-galated hain —
> ya to language/runtime ki zimedari hai ya vendor ka locked stack. Maine unki jagah
> wo diya jo Linux par actually possible hai, aur baaki ko 🚫 + reason ke saath chhoda hai.

### Display/GPU (desktop session ke liye) — kya-kya live me hai
- GPU KMS drivers live image me ship: `vmwgfx` (VMware/VBox VMSVGA), `vboxvideo`
  (VBoxVGA), `qxl`, `bochs`+`cirrus` (QEMU std/cirrus), `virtio_gpu`, `ast`,
  `mgag200`, `i915` (Intel), `nouveau`/`radeon` (purane NVIDIA/ATI).
- `S99zdisplay` hook (mdev/runtime ke baad) inhe explicitly load karta hai, aur
  final `fb=/drm=/driver=` status motd + `/run/pk/display.txt` me likhta hai;
  marker `DISPLAY-KMS` / `DISPLAY-TEXTONLY`.
- KMS na mile to weston ke bajaye `pk-x` Xvfb + `pk-desktop vnc <port>` se GUI
  reachable rehta hai (screen par nahi, network par haan) — kabhi fail nahi hoti.
- `amdgpu`/`xe` intentionally base live me nahi (firmware .bin ke bina probe fail
  karte hain + ~4 MB) — installed system / `pk-firmware` pack me wo cover hote hain.

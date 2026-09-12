# pk's OS · VM me test karne ki sheet (VirtualBox / VMware / QEMU)

VM test = **image + boot + install + apps layer** ka fast check. Jo cheezein VM me
*jantak* verify nahi hoti: asli GPU/KMS (weston ka DRM backend), USB stick ki speed,
Wi-Fi, BIOS/UEFI ka Secure Boot, aur terahz keyboard/touchpad. Unke liye pendrive chahiye
(sheet: [PENDRIVE.md](PENDRIVE.md)).

## 0. Kaunsi ISO (VM ke liye)
VM me agar display problema ho to **`pkos-1.0-serial.iso`** (same base OS, serial console default ON) use karo ✓

- **`pkos-1.0-apps.iso`** (700 MiB) = base OS + App Runtime (apt/Wine/weston) — **ye attach karo**
- `pkos-1.0.iso` (84 MiB) = base only (apps/GUI test nahi honge)

Download + verify:
```sh
sha256sum pkos-1.0-apps.iso   # d5803346c53a8c132d92bbabbf70521fdebf1c4f2e2c72e364be5d8a9e7ce9e4
```

---

## 1. QEMU (sabse fast, commands niche copy-paste)

### 1a. Sirf live boot dekhna (30 sec)
```sh
qemu-system-x86_64 -machine q35 -cpu max -smp 2 -m 2048 \
  -cdrom pkos-1.0-apps.iso -boot d \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -device virtio-gpu-pci -vga none \
  -audio none
```
GRUB menu aayega → `l` (live). Login: `root` / `pk` (live me autologin bhi hai tty1 par).

### 1b. Auto-pilot: boot + checks + report + poweroff (serial log me sab aayega)
```sh
qemu-system-x86_64 -machine q35 -cpu max -smp 2 -m 2048 \
  -cdrom pkos-1.0-apps.iso -boot d \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -serial file:vm-live.log \
  -append "" 2>/dev/null || true
# (GRUB ke default args me ye add karne hain - ya neeche wala direct-kernel raasta)
```
Iske liye sabse simple: **direct kernel boot** (GRUB skip), jo hamari QA bhi karti hai:
```sh
mkdir -p /tmp/pkiso && sudo mount -o loop,ro pkos-1.0-apps.iso /tmp/pkiso   # ya xorriso extract
qemu-system-x86_64 -machine q35 -cpu max -smp 2 -m 1536 \
  -drive file=/tmp/pkiso/live/pk.sqfs,if=none,id=sq,readonly=on \
  -cdrom pkos-1.0-apps.iso -boot d \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -kernel /tmp/pkiso/boot/pk-kernel -initrd /tmp/pkiso/boot/pk-initrd \
  -append "console=ttyS0 loglevel=4 pk_selftest pk_check=1 pk_tune=report pk_verify=1 pk_net=dhcp pk_halt" \
  -display none -serial file:vm-live.log
grep '### PK:' vm-live.log        # yahi expected output hai (section 3)
```
(VM me 1.5 GB RAM rakhna — desktop runtime mount + GUI ke liye; kam RAM pe `pk-desktop` skip ho sakta hai.)

### 1c. Install test (disk pe permanent)
```sh
qemu-img create -f qcow2 pk-disk.qcow2 40G
qemu-system-x86_64 -machine q35 -cpu max -smp 2 -m 2048 \
  -cdrom pkos-1.0-apps.iso -boot d \
  -drive file=pk-disk.qcow2,if=virtio \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
# live shell me:
pk-install --info                        # kaunsi disk milegi
pk-install --target=/dev/vda --user=ramesh --user-password=SecretPw
reboot -f                                # -cdrom hata ke dobara chalao -> disk se boot
```
Disk se boot karke: `dmesg | grep PK` me `RUNTIME-OK ... mode=rw-image (/var/lib/pk/…)`
aana chahiye (yaani apps + apt installed system me bhi zinda), aur login prompt
(`root` ya `ramesh`).

### 1d. UEFI (OVMF) test
```sh
qemu-system-x86_64 -machine q35 -cpu max -smp 2 -m 2048 \
  -bios /usr/share/OVMF/OVMF_CODE_4M.fd -cdrom pkos-1.0-apps.iso -boot d \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0
```
`OVMF_CODE.fd` path distro pe alag ho sakta hai (`/usr/share/ovmf/x64/…`).

---

## 2. VirtualBox / VMware settings

### ⚠️ Sabse common fail: UEFI + Secure Boot ON (VirtualBox 7.x)
Hamara GRUB **unsigned** hai, isliye UEFI Secure Boot on hone par OVMF use load hi nahi karta —
screen par kuch nahi/aap EFI shell dekh sakte ho, aur `VBox.log` me ye line dikhti hai:

```
Firmware type: UEFI
Secure Boot: Enabled        <- ye on hai to ISO boot nahi hogi
```

Do theek raaste (koi ek):
- **Simple**: Settings → System → Motherboard → **Enable EFI** *untick* (Legacy BIOS) — hamari QA isi path pe hai.
- **UEFI test karna ho**: Enable EFI **on** rakho, aur uske neeche aane wala
  **“Enable Secure Boot” *untick*** karo. (QEMU/OVMF me bhi yahi: `...,secure-boot=off` ya plain `-bios OVMF_CODE.fd`.)

Confirm karne ke liye VM ke baad: `VBoxManage showvminfo "<vm>" | grep -iE "firmware|secure"`

### Paste-able: VBoxManage se ek hi baar me sahi VM (screen wali halat se bahar)
Windows PowerShell me (VBox install dir se), ya Linux par as-is:
```
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" createvm --name pkos --register --ostype "Other Linux (64-bit)"
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" modifyvm pkos --firmware bios --memory 3072 --cpus 2 --vram 32 --graphicscontroller vmsvga --accelerate3d off --ioapic on --nic1 nat --nicertype82545em --boot1 dvd --boot2 disk --bootnone on
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" createmedium disk --filename $HOME\VirtualBox VMs\pkos-disk.vdi --size 40960 --format VDI
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" storagectl pkos --name sata --add sata --controller IntelAhci
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" storageattach pkos --storagectl sata --port 0 --device 0 --type hdd --medium $HOME\VirtualBox VMs\pkos-disk.vdi
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" storageattach pkos --storagectl sata --port 1 --device 0 --type dvddrive --medium C:\Users\you\Downloads\pkos-1.0-apps.iso
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm pkos --type gui
```
(`--firmware bios` line hi Secure-Boot wali problem khatam karti hai. EFI test karna ho:
`--firmware efi` ke saath `VBoxManage modifyvm pkos --firmware efi --bioslogofadein off` aur
**`--uart1` wala serial-port config** dekh lo neeche.)

### Screen hi na aaye? Serial-port -> file (VM headless, poori boot text file me)
```
VBoxManage modifyvm pkos --uart1 0x3F8 4 --uartmode1 file C:\Users\you\pk-serial.log
```
Do raaste:
- **`pkos-1.0-serial.iso`** (release ka 8th asset): isme default entry me hi
  `console=tty0 console=ttyS0,115200n8` hai → GRUB menu se kernel, `### PK:` markers aur
  **live root shell** sab us file me dikhte hain (yaani bina display ke bhi poora test) ✓
  Normal ISO me `c` (serial console) entry bhi yahi karti hai, par wo menu dikhne par hi select ho sakti hai.
- Apne build me: `make iso OUT=build/pkos-serial.iso PK_SERIAL=1` (ya `KERNEL_CMDLINE="quiet loglevel=3 console=tty0 console=ttyS0,115200n8"`)

### VirtualBox (7.x) — settings
| setting | value |
|---|---|
| Type / Version | Linux / **Other Linux (64-bit)** |
| RAM | base ISO: **768 MB bhi kaafi** (`make test` ka default hi 640 MB hai - usi par live-boot QA pass hota hai). apps ISO: **2048 MB** (GUI + apt + runtime ke liye comfortable); 1 GB ke aas-paas par /tmp (RAM-backed overlay) pressure se `APP-APPIMAGE-SKIP` type skips dikhe the - image ka bug nahi, RAM ki kami. 4-6 GB dene ki **zarurat nahi**, bas `toram` + ek saath bahut saari apps chalani ho to kaam aata hai |
| Page Execution / ballooning | default rakh do; VM ke andar swap ki zarurat nahi (hamara overlay RAM me hota hai). Chaaho to boot option `pk_swap=auto` (RAM/2, 1-8 GB clamp) - live me guard se skip (tmpfs par swapfile = RAM khana), installed/PK-PERSIST par `pk-swapfile` ban ke `swapon` |
| CPU | 2 core, **Enable I/O APIC** on |
| Chipset | ICH9 (PIIX9 se accha), *Nested PT* on agar available |
| Network | **NAT**, adapter type = **Paravirt NIC (virtio-net)** ya Intel PRO/1000 MT (82545EM) |
| Storage 1 (IDE/SATA secondary master ya SATA) | `pkos-1.0-apps.iso` (Live ISO) |
| Storage 2 (SATA) | 40 GB VDI (install test ke liye) |
| Display | Video RAM 128 MB, **3D acceleration OFF** (hamara GUI Xvfb se bhi chalta hai; on karne par GPU init fail ho sakta hai) |
| System → Motherboard → **Enable EFI** | UEFI test ke liye on, par **Secure Boot off** (upar wala box) |
| Boot order | Optical pehla |

### VMware Workstation / Player
- New VM → *Installer disc image file* = ISO → Guest: **Linux → Other Linux 5.x kernel 64-bit**.
- Firmware: **BIOS** (default) rakhna; UEFI test me *Options → Advanced → Firmware type: UEFI* +
  **Secure Boot OFF** (VMware UEFI me on hota hai by default — hamara GRUB unsigned hai, to boot nahi karega).
- RAM 2 GB+, 2 CPU, Network = NAT, Add → Hard disk (SAS/NVMe) 40 GB (install test ke liye).
- Display: "Accelerate 3D graphics" off rakhna (black screen ka common reason).
- `.vmx` me `svga.vramSize = 134217728` optional.

### Hyper-V (Windows pe)
Type-1 generation-2 VM + Secure Boot on hai to **Secure Boot off** karo ya "Microsoft UEFI CA"
template choose karo; better: Generation-1 + ISO attach. (Hyper-V par our live image ko
`hv_storvsc` modules chahiye — hamare image me nahi, isliye **VirtualBox/VMware/QEMU preferred**.)

---

### Serial log kaise nikalein (mujhe bhejne ke liye useful)
VirtualBox: Settings → Serial Ports → Port 1 → **Check "Enable Serial Port"**, Port Mode =
**Raw File / Log File**? (VBox me "File" mode chunein), Path = `C:\Users\you\pk-serial.log`,
**Connect to existing file = off**. Phir GRUB entry me `e` dabakar line ke aage add karo:
`console=ttyS0,115200n8 pk_check=1 pk_selftest pk_poweroff`
→ poori boot log file me aa jaayegi (markers + pk-check table).

## 2b. Graphics device ka chunav — desktop (weston) ke liye ye zaroori hai

`pk's OS` ka text console har device par chalta hai. **Desktop session (weston) ko
DRM/KMS device chahiye** (`/dev/dri/card0`). Live image me ab ye drivers ship hote
hain: `vmwgfx vboxvideo qxl bochs cirrus virtio_gpu ast mgag200 i915 radeon nouveau`
(iske liye ISO ~3.6 MB badi hui — 88 MB -> 92 MB — desktop ke muqable sasta saudagar).

| Host | Device flag | Result (QEMU 10 + kernel 6.12 par naapa gaya) |
|---|---|---|
| QEMU | `-vga std` (default) | `bochs` driver bind -> `/dev/dri/card0` -> **desktop aata hai** |
| QEMU | `-vga virtio` | `virtio_gpu` -> desktop, fastest |
| QEMU | `-vga qxl` | `qxl` -> desktop (SPICE ke saath) |
| QEMU | `-vga vmware` | `vmwgfx` load hota hai par probe fail: `Hardware has no pitchlock` / `probe with driver vmwgfx failed with error -38` — **QEMU ka VMware emulatikon SVGA v2 tak hai**, kernel use reject karta hai. Text console theek, desktop nahi. (Asli VMware/VirtualBox VMSVGA me ye device SVGA v3+ deta hai wahan vmwgfx chalta hai.) |
| VirtualBox | `--graphicscontroller vmsvga` | `vmwgfx` -> desktop on-screen ✅ (VBox ka default bhi yehi) |
| VirtualBox | `--graphicscontroller vboxvga` | `vboxvideo` -> desktop on-screen |
| VirtualBox | `--accelerate3d on` | zaroori NAHI; 3D off par bhi weston (pixman) chal jaata hai |

Note: is Debian kernel me `CONFIG_DRM_SIMPLEDRM`/`CONFIG_SYSFB_SIMPLEFB` **band**
hain — yaani "koi driver nahi to basic framebuffer to chalega" wala raasta available
hi nahi. Isliye GPU module list itni matter karti hai. AMD ke naye GPUs (`amdgpu`)
aur Intel Arc (`xe`) deliberately nahi hain: woh `/lib/firmware/{amdgpu,xe}/*.bin`
maangte hain (na mile to probe fail) + ~4 MB — un par text console +
`pk-desktop vnc` chalega, full support installed system me (firmware pack ke saath).

Boot ke baad screen par desktop aaya ya nahi, ye **do marker** batate hain
(`### PK: ... ###`, ya `/etc/motd` ke upar wali `[ pk-display-status ]` line):

- `DISPLAY-KMS (drm=1 driver=bochs-drm fb=1)` -> KMS device ready; weston ko `/dev/dri/card0`
  milta hai (ye QEMU `-vga std` par naapa gaya actual result hai)
- `DISPLAY-TEXTONLY (fb=0 drm=0; ...)` -> device nahi: screen par text aayega,
  desktop `pk-desktop vnc 5900` se dekho (Xvfb fallback) — ya VM ka graphics device badlo
- `DESKTOP-OK (wayland-1)` -> **weston KMS par chalu, screen par desktop aayega** ✅
- `DESKTOP-OK (:0)` -> session Xvfb(par) — apps chalenge par physical screen par kuch nahi
- `DESKTOP-WESTON-LOG ...` -> weston ka aakhri notice/error, marker me hi (debug ke liye)
- `DESKTOP-NO-RUNTIME` -> ye base/serial ISO hai; desktop apps ISO me hota hai

Guest me aur cheezein check karni ho to boot option `pk_run=<cmd>`:
`+` = space, `!` = commands ka separator (`;` GRUB khaata hai, isliye nahi chalta) —
jaise `pk_run=cat+/run/pk/x-weston.log!ls+-l+/dev/dri`

## 3. VM me andar jaake ye 8 commands (expected output ke saath)

```sh
pk-info                    # mode=live, media, kernel, net, runtime ka haal
pk-check --save            # table; end me: ### PK: CHECK-SUMMARY ok=N fail=0 ... ###
dmesg | grep PK            # BOOT-OK, NET-OK, DEPS-OK, MDEV-OK, RUNTIME-OK/APPS-*, VERIFY-OK
pk-run --selftest          # ### PK: APPS-OK ###  (ELF/script/.deb/.exe/AppImage/jar/rpm/.ipa/.apk)
pk-net dhcp                # (agar pk_net=dhcp nahi diya) -> ### PK: NET-OK (10.0.2.15) ###  QEMU NAT me
pk-get install -y htop     # runtime ke andar apt (QEMU user-net se internet ✓)
pk-run --gui htop          # Xvfb session par (pk-x start pehle, agar nahi chala to)
pk-desktop ; pk-desktop outputs
```

Pass ka matlab — `dmesg`/console par ye lines (VM me kuch optional skip ho sakte hain):
```
### PK: BOOT-OK mode=live kernel=6.12.x media=/dev/sr0 ###
### PK: MDEV-OK (hotplug=/bin/mdev) ###
### PK: DEPS-OK ###
### PK: NET-OK (10.0.2.15) ###            # pk_net=dhcp diya ho
### PK: RUNTIME-OK src=pk-runtime.sqfs ... mode=tmpfs (ephemeral) ###
### PK: APPS-OK ###
### PK: VERIFY-OK (pk.sqfs) ###           # pk_verify=1 diya ho
### PK: CHECK-OK (N checks, 0 fail) ###
### PK: DESKTOP-OK (:0) ###               # pk_desktop=1 / pk-desktop chalao to
```
`mode=tmpfs (ephemeral)` **sahi hai** — live ISO read-only hai; persistence ke liye
`persistent` boot option ya installed system (`/var/lib/pk/pk-runtime-rw.img`).

## 4. VM me common atakne aur fix

| lakshan | kaam |
|---|---|
| "no bootable device" / seedha shell | ISO attach nahi hua ya boot order me nahi; QEMU me `-cdrom X -boot d` |
| black screen (GRUB ke baad) | GRUB menu me `e` dabao, `linux` line ke aage `nomodeset` add karo; ya `c` (serial console) entry; VirtualBox me 3D acceleration OFF |
| VirtualBox EFI on karne par kuch nahi | EFI + Secure Boot band karo; ya BIOS me wapas |
| net nahi milta | VM ka NIC virtio/82545EM select karo, phir `pk-net dhcp`; `ip link` se `eth0` up? `dmesg | grep -i link` |
| pk-desktop fail | `pk-x status`, `tail /run/pk/x.log`; runtime me weston/xvfb hai? `pk-run --list`; phir `pk-get install -y weston xterm xvfb x11-utils` |
| pk-get slow/timeout | apps-ISO me apt lists andar hain; agar base ISO hai to pehla `update` 40 MB khinchta hai — 2 GB RAM rakho, ya `pk-get update` ko chhodo aur `--no-install-recommends` use karo |
| install ke baad disk se boot nahi | VM ke first boot device ko disk banao; GRUB install log dekho: `cat /run/pk-install.log` (live me) |
| RAM kam (512 MB) | GUI/Wine skip honge; `pk-check` me `warn` aayega (fail nahi) — 1.5-2 GB do |

---

## "GRUB ka menu dikha, phir screen kaali" — timeline, causes, fixes

QEMU `screendump` se maape hue asli numbers (VirtualBox window me bhi wahi hota hai);
`tools/vm-shot.sh` se khud dobara bana sakte ho:

| time | screen | matlab |
|---|---|---|
| 0-15 s | GRUB menu | theek: image, GRUB, ISO padhna sab chal raha hai |
| ~15-25 s | **poori kaali** (non-black pixels 0.2 %) | kernel + KMS/fbcon handoff - **ye normal hai**, is window me kuch print hi nahi hota |
| ~25 s ke baad | `### PK: BOOT-OK ... ###`, motd, `login: root  password: pk` | live system chalu ✓ |

Isliye **pehle 60 second ruko** (sasti USB + apps ISO par 90 s tak lag sakte hain). Phir bhi kaali
rahe to isi order me try karo:

1. **`--type headless` se start kiya? To window kabhi nahi dikhegi** (aapke bheje hue log me
   headless start tha). GUI ke saath: `VBoxManage startvm <vm> --type gui`.
   Headless me screen dekhne ka sahi tareeqa (GUI nahi chahiye):
   `VBoxManage controlvm <vm> screenshotpng /tmp/vm.png`  ← hamare `tools/vm-shot.sh` ka VirtualBox version.
2. **Safe graphics entry** chuno: boot menu me `v` (nomodeset) ya `b` (nomodeset + serial console).
   GRUB-ke-baad kaali screen ka #1 reason GPU handoff hota hai (VBox VMSVGA + 3D on, ya aisa
   physical GPU jise kernel ka `simpledrm` pasand nahi aata).
3. **VBox: 3D off + controller badlo** (Windows host par Hyper-V/NEM ke saath aksar atakta hai):
   ```bash
   VBoxManage controlvm <vm> poweroff
   VBoxManage modifyvm <vm> --accelerate3d off --graphicscontroller vmsvga --vram 128
#   (vmsvga = VMware SVGA; live me vmwgfx+bochs+vboxvideo ship hote hain -> desktop on-screen
#    aana chahiye. Agar DISPLAY-TEXTONLY dikhe to 'v' = safe-graphics entry use karo.)
   VBoxManage startvm <vm> --type gui
   ```
   (VBoxVGA purana hai par text-mode ke liye robust; VMSVGA 3D ke liye - dono par hamara GUI
   Xvfb/backend-safe se chalta hai, isliye 3D off karne se GUI test nahi bigdega.)
4. **RAM**: apps ISO ke liye 2048 MB se kam par /tmp (RAM) pressure se boot atak sakta hai.
5. **Guaranteed visible path = serial console**: `pkos-1.0-serial.iso` +
   `VBoxManage modifyvm <vm> --uart1 0x3F8 4 --uartmode1 file /home/you/pkos-serial.log`
   (ya `--uartmode1 client 127.0.0.1:5555` → `nc -l 5555`). Kernel ki pehli line se login tak
   sab text aata hai - screen/GPU/GRUB se bilkul independent.
6. Physical PC: GRUB me `e` dabakar `nomodeset` add karo, ya `video=efifb:off` (UEFI), aur
   BIOS me CSM/Legacy on karke dekho.

Image me kya add kiya hai (har boot par automatically chalta hai):
- `etc/pk-boot.d/S08display` hook: har `fb*/blank` ko 0 (unblank), VT par DPMS-off + cursor-on
  (`ESC[9;0]` + `ESC[?25h` - busybox me `setterm` nahi hota, isliye raw escape), laptop backlight
  `bl_power=0` + `brightness=max_brightness`, aur `/dev/tty1` par ek "console zinda hai" line —
  taaki *screen blanking* aur *boot atakna* turant alag dikh jayein. Log marker:
  `### PK: DISPLAY-OK (text=on fb=N drm=M, bl:...) ###` (text console theek hai - fb na ho tab bhi
  screen par text aata hai) ya `### PK: DISPLAY-NOCONSOLE ###` (sach me koi console nahi -> tabhi kaali screen).
  Band karna ho to boot option `pk_display=off`.
- Default kernel cmdline: `consoleblank=0 vt.global_cursor_default=1`.
- 2 naye GRUB entries: `v` = safe graphics (nomodeset), `b` = nomodeset + serial.
- `pk-check` me `backlight` + `fb-blank` rows (report `/run/pk/check.txt`).
- `tools/vm-shot.sh build/pkos.iso /tmp/shot 40` → VM ki screen PNG + "VISIBLE/BLACK" % (script khud
  count karta hai; hamare QA me bhi isi se verify hua tha).

---

## Aur agar `Secure Boot: Enabled` bilkul hata hi nahi sakta (Windows 11 PCs par aksar locked)

Hamara GRUB **unsigned** hai, isliye Secure Boot on machine par (VM ya PC) loader load hi nahi hota:
screen par kuch nahi, ya sirf "Failed to open \EFI\BOOT\BOOTX64.EFI". 3 raaste:

1. **BIOS/Legacy mode me boot karo (sabse aasan, Secure Boot yahan lagu hi nahi hota)**
   - VirtualBox: `VBoxManage modifyvm <vm> --firmware bios` (default VM naye banane par BIOS use karti hai)
   - VMware: `.vmx` me `firmware = "bios"` (ya .vmx delete karke VM dobara banao)
   - QEMU: `-bios /usr/share/OVMF/OVMF_CODE_4M.fd` **ki jagah kuch mat do** = SeaBIOS (default) ✓
   - Physical PC: boot manager (F12/Esc) me "UEFI: Kingston..." ki jagah bina UEFI- prefix wala entry
     chuno, aur BIOS setup me **CSM / Legacy / Boot Mode = Legacy or Both** kar do.
     (Kuch naye laptops me CSM option nahi hota - tab raasta 2 ya 3.)
2. **Ek baar Secure Boot temporarily off** karke boot ho jaye to: OS install ho jaane ke *baad*
   phir on kar sakte ho — par tab tak hamara GRUB bhi unsigned rahega, to Secure Boot on par
   installed OS bhi nahi chalega. Yaani ye sirf test ke liye theek hai.
3. **Hamare build me aap khud sign kar sakte ho** (roadmap item; abhi auto nahi):
   Canonical ka pre-signed `shimx64.efi` + `grubx64.efi` leke `/EFI/BOOT/BOOTX64.EFI` ki jagah
   rakho, aur apna MOK banao:
   ```bash
   sudo apt-get install -y shim-signed mokutil sbsigntool
   sudo sbkeysync --pk --export db.auth >/dev/null 2>&1 || true      # optional
   sudo mokutil --import /path/apna-mok.der                          # reboot par enroll hoga
   # phir ISO stage me: cp /usr/lib/shim/shimx64.efi.signed build/work/iso/EFI/BOOT/BOOTX64.EFI
   ```
   (SBS-signing ka apna key chain banana physical Secure-Boot PC ke liye hota hai; hamare QEMU
   OVMF test me `secure-boot=off` rakhna hi reasonable hai, kyonki target machine ka OEM db needed hota hai.)
4. **Secure Boot ON chhodna ho aur phir bhi boot chahiye**: `pkos-1.0-serial.iso` + BIOS firmware
   (raasta 1) combination sabse robust hai — hamare QA me 1000+ boots isi se hue hain.

**Note (image ka behaviour):** GRUB menu me 2 entries serial console par bhi print karti hain —
`c` = `pkos-1.0.iso` wali serial entry, `b` = safe-graphics + serial (nomodeset + serial).
Aur poori ISO ko serial-first banane ke liye: `make iso PK_SERIAL=1` (release me already
`pkos-1.0-serial.iso` as a separate asset hai). Screen black rahe to in entries se poora boot log
mil jaata hai, phir cause (GPU vs blanking vs atka boot) clear ho jaata hai.

## 5. Mujhe kya bhejo (agar kuch atke)
```
vm-live.log (ya serial screenshot)
pk-check --save ka /run/pk/check.txt (VM me file nahi bachti to: cat /tmp/pk-check.txt)
dmesg | grep PK
VM ka config (RAM/NIC/firmware) + ISO ka sha256
```

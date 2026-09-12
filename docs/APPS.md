# Running applications

pk's OS keeps the base image tiny (busybox + your kernel) and puts everything else in a
separate, optional **App Runtime**: a Debian userland built by `debootstrap` on your
machine, compressed with squashfs, mounted at `/opt/pk` at boot. It has its own `apt`,
its own `wine`, its own `/var`, and it cannot break the base system.

```
build/pk-runtime.sqfs  ->  /opt/pk        (read-only base)
                     rw  ->  /opt/pk-upper (your installs, ephemeral unless persistent)
```

## 1. Getting a runtime

| Way | Command |
|---|---|
| inside the ISO | `make runtime-desktop && make apps-iso` → `build/pkos-apps.iso` |
| lean runtime (console tools only) | `make runtime` (or `make runtime VARIANT=dev`) |
| on a partition/file of any USB stick | `pk-runtime --setup /path/pk-runtime.sqfs [dev]` |
| downloaded at boot | `pk_apps_get=<name-or-url>` (see below) |
| off entirely | `pk_runtime=off` |

`pk-runtime status` prints where it came from, whether the writable upper exists, and
what is mounted; the boot log line is `### PK: RUNTIME-OK src=… upper=… mode=… ###`.

## 2. Already installed (the "essentials" set)

The published `apps` image ships, inside the runtime, a normal desktop OS starting set —
no `pk-get` needed, works offline:

* editors / shell: `vim`, `nano`, `less`, `bash-completion`, `man-db`, `locales`, `sudo`, `dialog`
* files / archives: `tree`, `pv`, `zip`, `unzip`, `p7zip-full`, `xz-utils`, `patch`, `diffutils`, `file`
* system / processes: `htop`, `procps`, `psmisc`, `ncdu`, `lsof`, `strace`, `bc`, `time`, `watch`, `make`
* network: `iproute2`, `iputils-ping`, `dnsutils` (`dig`, `nslookup`), `iperf3`, `ethtool`, `socat`, `wget`, `curl`, `openssh-client`, `openssh-sftp-server`, `ca-certificates`, `gnupg`, `pinentry-curses`
* USB/PCI/SMBIOS: `pciutils`, `usbutils`, `dmidecode`
* language: `python3`, `python3-venv`
* wireless + Bluetooth: `wpasupplicant`, `iw`, `wireless-tools`, `crda`, `wireless-regdb`, `rfkill`, `bluez`, `bluez-obexd`
* GUI basics: `weston`, `xterm`, `Xvfb`, `mesa-utils`, `x11-utils`, `xkb-data`, fonts, icons, `seatd`, `alsa-utils`, `xwayland`
* media / documents: `dillo` (browser), `sxiv` (images), `mupdf-tools` (PDF), `mpg123` (audio)
* Windows layer: `wine`

The build writes the exact list it found into the runtime as `/etc/pk-essentials.txt`, and
every boot turns it into `### PK: ESSENTIALS-OK (count=NN missing=0) ###` — so
"pre-installed" is checked by QA, not asserted. If the apps image was built without
them (older runtime), the marker says `ESSENTIALS-PARTIAL (missing=…)` / `ESSENTIALS-SKIP`.

Anything else: `pk-get update && pk-get install -y <pkg>` (Debian's apt, in the runtime;
package indexes are already inside the image, so a normal install only downloads the
`.deb` files).

## 3. `pk-run`: one entry point, several ecosystems

```sh
pk-run ./AppImage-file            # sets the executable bit, runs it (FUSE-less extract fallback)
pk-run ./pkg.deb                  # installs into the runtime via apt (deps resolved)
pk-run ./pkg.rpm                  # converted/extracted, then run
pk-run ./Setup.exe                # wine (prefix in the runtime's writable layer)
pk-run ./app.jar                  # java -jar (install a JRE with pk-get if you need it)
pk-run ./script.sh                # interpreter from the runtime
pk-run ./hello-arm64              # ELF with e_machine=AArch64 -> qemu-user (see §4)
pk-run https://example.com/app.deb      # download, verify type, then install
pk-run --gui ./gimp               # export WAYLAND_DISPLAY/DISPLAY first (needs pk-desktop/pk-x)
pk-run --list                     # launchers created so far
pk-run --info <file>              # what it thinks the file is, and why
pk-run --selftest                 # the QA battery (used by 'make test')
```

`pk-run` reads the ELF header (magic + `e_machine` at offset 18) rather than trusting the
extension, and prints `APP-ARCH-OK`/`ARCH-DISPATCH-OK` when it hands a foreign-arch
binary to `qemu-user`.

## 4. Other architectures

```sh
pk-binfmt register        # binfmt_misc handlers -> runtime's qemu-<arch>-static
pk-binfmt status
pk-get install -y qemu-user-static     # if the runtime lacks them
```
Registered handlers: `pk-aarch64`, `pk-arm`, `pk-riscv64`, `pk-ppc64le`, `pk-s390x`.
This is user-mode emulation: correct for running a foreign binary, not for GPU-heavy or
timing-sensitive programs.

## 5. Windows programs

Wine lives in the runtime, so `pk-run Setup.exe` / `.msi` works out of the box in the
apps image. Notes that matter in practice:

* the Wine prefix is inside the runtime's writable layer → it disappears on reboot
  unless you use `persistent` or install to disk;
* 32-bit installers need a 32-bit Wine build: `pk-get install -y wine32` (multiarch);
* GPU acceleration is the same KMS device the desktop uses — on `amdgpu`/`xe` machines
  you get llvmpipe (software), which is enough for office-style apps;
* `wine` prints a lot on first run; run it through `pk-run --gui <app>` inside a session
  and check `/run/pk/desktop.log`.

## 6. GUI apps need a display

```sh
pk-desktop start         # weston on the KMS device (+ weston-terminal), or
pk-x start Xvfb          # headless, then pk-desktop vnc 5900
pk-desktop app ./gimp    # = pk-run --gui, but with the session env set
```

## 7. Known gaps (deliberate, so you are not surprised)

* no Flatpak/Snap daemons — use `.deb`/AppImage (or `pk-get`) instead;
* no `systemd` in the base or the runtime: services are `pk-boot` hooks and the
  runtime's own `service`/init scripts;
* `pk-chroot`, `pk-shell`, `pk-get` require root (they `chroot`); normal users run apps
  through `pk-run`, which is designed for that;
* iOS apps: not possible (see [IOS-ANDROID.md](IOS-ANDROID.md)); Android apps need a
  Waydroid image and binder support.

# The kernel: default, and building your own

## Default: the host kernel

`make iso` takes the newest `/boot/vmlinuz-*` on the build host plus the matching
`/lib/modules/<ver>` set, and copies only the modules listed in `init/kernel-modules`
(into the initramfs, with their dependency closure) and `config/live-modules.txt` (into
the live filesystem). `config/live.conf` exposes it as `PK_KERNEL` / `PK_MODULES`:

```sh
make iso PK_KERNEL=/boot/vmlinuz-6.12.9 PK_MODULES=/lib/modules/6.12.9
```

That is why the build needs no kernel toolchain, and why the ISO stays ~95 MB: the
kernel already exists on your machine and is the one your hardware boots today.

## Your own kernel

```sh
make kernel                     # scripts/build-kernel: download, configure, build, modules_install
scripts/build-kernel config     # regenerate the .config only
make iso PK_KERNEL=$PWD/build/kernel-6.12/bzImage PK_MODULES=$PWD/build/kernel-6.12/modules
```

Details:
* version: `PK_KVER` (default `6.12`), source dir `PK_KSRC`, tarball from kernel.org,
  `JOBS` for parallelism;
* configuration philosophy: everything needed to reach the root filesystem is built in
  (`=y`: ext4, vfat, iso9660, squashfs, overlay, loop, USB/ATA/NVMe), optional hardware
  stays a module (`=m`) — so the initramfs is tiny and the ISO picks your GPU/sound/Wi-Fi
  driver at runtime;
* `config/live-modules.txt` is matched against your new `modules` tree; a module that is
  built in is skipped automatically (`modprobe --show-depends` based);
* useful config fragments are printed by `pk-android kernel-frag` (Android/binder) and can
  be merged into the `.config` before `make kernel`.

## Boot-time module behaviour in the live system

busybox **mdev** is the udev replacement: `etc/mdev.conf` runs `@/etc/mdev/hotplug.sh`
on every rule (mdev applies only the first matching rule, hence the repetition), which
`modprobe`s the driver for the device that just appeared, then `pk-devperms` fixes group
and mode. Coldplug at boot is `mdev -s`, from `S15mdev`, marker `MDEV-OK`.

Practical consequences:
* a driver that needs firmware (`iwlwifi`, `amdgpu`, some `snd-*`) will load and then
  log `Direct firmware load … failed` — copy the blob into `/lib/firmware` (persistent
  stick or installed system) or `pk-get install -y firmware-…` in the app runtime;
* adding a driver is one line in `config/live-modules.txt`, no other change needed;
* `nomodeset` on the boot line skips the GPU drivers (KMS-free console, VNC desktop);
* Secure Boot: this kernel is not signed, so keep Secure Boot off or enroll your own key
  with `mokutil` in the runtime.

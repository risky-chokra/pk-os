# iOS and Android apps: what is true, and what to do instead

Short answer: an `.ipa` cannot run on this OS, an `.apk` can run only with extra parts
that are not in the base image. Both tools, `pk-ios` and `pk-android`, exist so that you
get the diagnosis, the file inspection and the working route instead of a broken promise.

## iOS / iPadOS (`.ipa`)

Why native execution is impossible:
1. the binary format is **Mach-O** and the syscalls are **XNU/BSD**, not Linux ELF/syscalls;
2. every iOS binary is **code-signed** against Apple's TEE/App ID chain — an unmodified
   iOS binary will not run on a device Apple has not attested;
3. the app links against **UIKit/SwiftUI/Metal/CoreLocation**, closed frameworks with no
   Linux implementation; and Apple's EULA restricts iOS to Apple hardware.

So no "iOS emulator for x86 PC" exists in the way Wine exists for Windows: there is
nothing on the machine that can host the frameworks.

What you *can* do, in the order of practicality:

```sh
pk-ios why                       # this explanation, one line at a time
pk-ios doctor                    # what this machine/runtime has (qemu, kvm, mac tools)
pk-ios info App.ipa              # bundle id, minimum iOS, archs, what would be needed
pk-ios extract App.ipa outdir    # payload inspection (Contents/Info.plist, *.app)
pk-ios web <url>                 # a mobile site is the real cross-platform answer
pk-ios mac-guest [--run]         # writes/runs a QEMU macOS guest recipe, then Xcode Simulator
pk-ios darling                   # notes on Darling (macOS *binaries*, not iOS apps)
```

Routes that actually work:
* **Web app / PWA** in the shipped `dillo` or in a browser you install with
  `pk-get install -y firefox-esr`: `pk-ios web <url>` prints the mobile-UA recipe. This
  is what most iOS apps really are, plus a native shell.
* **macOS guest + iOS Simulator** (`pk-ios mac-guest`): QEMU with OpenCore
  (`opencore-ia32/ia64` images are published by the Axose project), then Xcode's iOS
  Simulator inside macOS. Needs ~40 GB disk, a licensed macOS, and is slow; the tool
  writes the `pk-vm` command and the checklist for you. This is a *development* path
  (build/run/debug), not a "run App Store apps" path, because of point 2 above.
* **Darling** (`pk-ios darling`): a macOS compatibility layer for **macOS** command-line
  binaries. It does not run iOS apps, and it is not in the runtime yet — the tool tells
  you what it would take.
* If you own the source: rebuild the app for Linux. Flutter, Qt, SDL, Godot, Electron
  and Unity all export Linux — that is a real, supported path (`pk-run` then handles
  the produced ELF/AppImage/deb).

## Android (`.apk`)

An `.apk` is a ZIP of DEX + resources + optional native ELF for `arm64-v8a`. The
blocking pieces are not the CPU (our `qemu-user` path already runs foreign ELF) but:

1. the **Android framework** (Activity/PackageManager/SurfaceFlinger) — a whole OS, not a library;
2. **binder** (`/dev/binder` or binderfs) — Linux needs `CONFIG_ANDROID_BINDERFS`;
3. usually **ARM-only** native code + the NDK ABI expectations;
4. Google Play's safety/attestation for many commercial apps.

```sh
pk-android doctor            # binder/ashmem/kvm/waydroid/adb status on this system
pk-android enable            # try to mount /dev/binderfs (works if the kernel has it)
pk-android kernel-frag       # the CONFIG_* fragment for 'make kernel' (binder, ashmem)
pk-android install app.apk   # unpack + tell you exactly what is still missing
pk-vm new android --size=20G # emulator route: Android-x86 / Waydroid image as a VM
```

Working routes today:
* **Waydroid** — after `pk-android kernel-frag` is built into your own kernel
  (`make kernel`, `CONFIG_ANDROID_BINDERFS=y`), plus `pk-get install -y waydroid` in the
  runtime. `pk-android doctor` says which of those two are missing.
* **A VM with Android-x86/Bliss OS** via `pk-vm` (needs KVM: `pk-check` shows the `kvm` row).
* **`scrcpy`** (`pk-get install -y scrcpy adb`) to mirror and control a real phone you
  already own — for testing an app on genuine hardware this beats any emulator and it is
  what most people actually want.
* Rebuild the app for Linux (Flutter/Qt/Godot/SDL) — same advice as iOS.

## What the QA covers

`make test` asserts the honest behaviour, not magic: `pk-ios why`/`info` on a synthetic
`.ipa` (it must identify Mach-O and refuse politely), `pk-run --info` on the same file,
`pk-android doctor` reporting binder/kvm state, and the `APP-*` markers for the paths
that do work (Linux ELF, scripts, `.deb`, AppImage, `.exe` through Wine, foreign-arch
ELF through `qemu-user`). If a claim in this file ever stops matching the code, that is
a bug worth reporting.

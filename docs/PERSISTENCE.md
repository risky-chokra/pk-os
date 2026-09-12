# Persistence, and what is kept where

## Live session without persistence (the default)

| Where | Backing | Survives reboot |
|---|---|---|
| `/` (root) | squashfs, read-only | n/a — never changes |
| `/etc`, `/var`, `/usr/local`, … | `overlayfs` upper dir in RAM | **no** |
| `/tmp`, `/run` | tmpfs | no |
| `/root`, `/home` | RAM overlay | no |
| `/opt/pk` (app runtime base) | squashfs, read-only | n/a |
| runtime's apt installs, Wine prefix | `pk-runtime-rw.img` (RAM if the medium is read-only) | no |

So in a plain live boot: added users, `pk-keymap`, installed packages, desktop
settings — all of it is gone after reboot. This is by design (a live image you can trust
to always come back), and it is exactly what the next two sections fix.

## 1. Persistence partition on the stick

```sh
pk-persist                 # auto-detects the live medium (or: pk-persist /dev/sdX)
```
It uses the unpartitioned space at the end of the stick, creates one ext4 partition with
label `PKPERSIST`, and moves the overlay's `work`+`upper` there. Then boot with the
option `persistent` (GRUB: press `e` and append it). Optional label: `persistent=MYDATA`.

Notes:
* The stick's ISO area is never rewritten; your data lives in the new partition, so
  `pk-check` and the installer still see a valid hybrid layout.
* To see what is actually persistent: `mount | grep -E 'overlay|PKPERSIST'` and
  `pk-info` (both print the live medium, the mount mode and the overlay upper dir).
* Speed matters: on a slow USB 2.0 stick the overlay is the bottleneck; `pk-check --speed`
  measures it. `toram` + `persistent` is a bad combination (RAM copy loses the
  persistence mount) — choose one.

## 2. What persistence actually stores

Because it is an `overlayfs` upper dir: everything under `/etc`, `/var`, `/root`,
`/home`, `/usr/local` (so also `~/.config`, ssh host keys, `pk-user` changes,
firmware you dropped in `/lib/firmware`), plus the app runtime's writable image when it
is placed on the stick (`pk-runtime --setup` puts `pk-runtime-rw.img` next to the `.sqfs`).
Deletions are recorded as whiteouts — normal overlayfs behaviour.

`pk-persist` takes no flags — the state is visible with `pk-runtime status` and
`mount | grep -E 'overlay|/opt/pk'`.

## 3. Installed system (the durable answer)

```sh
pk-install --target=auto --user=bob --hostname=pkbox
```
The installer copies the payload to a real partition layout, so persistence is no longer
relevant: `/etc` and `/home` are ordinary ext4, updates are your business, GRUB comes
from the disk. `--no-runtime-copy` keeps the app runtime on the stick only.

## 4. Backups

The stick is disposable; the *recipe* is the durable object. Keep the git repo (and the
release's `manifest.txt`), and if you want a copy of the built artifacts:

```sh
tools/restore-from-iso.sh build/pkos-apps.iso   # extracts rootfs/overlay back out of an ISO
```
(the ISO doubles as a backup of the live tree, which is how a wiped workspace has been
recovered more than once).

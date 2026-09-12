# Release contents and how to publish

## Assets in a release

| Asset | What it is |
|---|---|
| `pkos-<ver>.iso` | base live system: boot, console, network, users, installer, device modules (~95 MB) |
| `pkos-<ver>-apps.iso` | the same **plus** the Debian app runtime: weston desktop, Wine, the essential tool set, Wi-Fi/Bluetooth tools (~600 MB) |
| `pkos-<ver>-manifest.txt`, `pkos-<ver>-apps-manifest.txt` | byte size, SHA-256, git commit, build host, kernel, squashfs parameters, and the SHA-256 of every payload file inside the image |
| `pkos-<ver>-src.tar.gz` | the source tree (no `build/`) |
| `pkos-main.bundle` | `git bundle` of the whole history - `git clone` it if GitHub is unavailable |
| `pkos-<ver>-essentials.txt` | the exact essential-command list the build found inside the runtime (`/etc/pk-essentials.txt`) |

"Flash this" instruction in the release notes: **`apps.iso` is the one to write to a
USB stick.** The base ISO is for people who want the smallest possible bootable system.

## Verification before publishing

```sh
make kit                      # ISOs + manifests + bundle + src tarball
make test                     # 8-stage QEMU QA suite; must print 'QA PASS'
PK_TEST_GUI=1 make gui-test   # the kit/GUI stage again, incl. desktop + seatd + users
tools/verify-usb.sh build/pkos-apps.iso          # layout / hybrid bits / GPT checks
```

`make test` is not cosmetic: it boots the image in QEMU eight times (live, FAT32 media,
frugal ISO file, install to disk, installed boot, `toram`, UEFI/OVMF, persistence + DHCP
+ SSH, app dispatch, the USB kit stage) and greps the `### PK: … ###` markers, so a
regression in the boot path fails the release instead of the user.

## Publishing

```sh
export GITHUB_TOKEN=…            # classic PAT, scope: repo   (fine-grained tokens
                                 # cannot create a repository)
OWNER=risky-chokra REPO=pk-os VERSION=1.1 TAG=v1.1 tools/publish.sh
```
Defaults in the script are `OWNER=risky-chokra REPO=pk-os`, so `VERSION=1.1 tools/publish.sh`
is enough; override with env vars.

`tools/publish.sh` will, idempotently: create the repo (public) if missing → push
`main` → create the tag → create the release with the notes from `docs/RELEASE-NOTES.md`
(or `STATUS.md`) → upload the assets → verify by listing the release and comparing each
asset's size and SHA-256 against `build/manifest*.txt` → print the release URL. It never
prints the token, and it writes it only to `~/.netrc` for the duration of the git push
(`shred` afterwards, and revoke the token once the push is done).

```sh
git remote add origin https://x-access-token:$GITHUB_TOKEN@github.com/OWNER/pk-os.git   # manual fallback
git push origin main --follow-tags
gh release create v1.1 build/pkos-1.1-apps.iso … -t "pk's OS 1.1" -F docs/RELEASE-NOTES.md   # if gh exists
```

The manual fallback is also what you use if you prefer to create the repository in the
web UI: then `tools/publish.sh --no-create` skips creation and only pushes + releases.

## Notes for the release text

Keep it factual. Say what is verified (with the marker names and the QA counts), what is
only verified in QEMU, and what needs the user's hardware (audio output, Wi-Fi firmware,
accelerated `amdgpu`/`xe` — the latter two are not shipped at all). State the sizes from
`manifest*.txt`, not from memory, and never describe `docs/` claims as tested unless a
`make test`/`gui-test` line covers them.

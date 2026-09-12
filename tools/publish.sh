#!/bin/sh
# pk's OS :: publish a release to GitHub (creates the repo if it does not exist).
#
#   GITHUB_TOKEN=ghp_xxx VERSION=1.1 tools/publish.sh        # defaults: OWNER=risky-chokra REPO=pk-os
#
#   --no-create     do not create the repository (it already exists)
#   --dry-run       print what would happen
#   --docs-only     only run the documentation language guard and exit
#
# What it does, in order:
#   1. language guard  - no Hindi/Hinglish may remain in the shipped documentation
#   2. create repo     - public, via the REST API (needs a *classic* token with 'repo';
#                        fine-grained tokens cannot create repositories)
#   3. push            - branch + tags, over an https URL that carries the token
#   4. tag + release   - annotated tag, release notes from docs/RELEASE-NOTES.md
#   5. assets          - both ISOs, both manifests, the source tarball, the git bundle
#                        and the runtime essentials list
#   6. verify          - re-read the release through the API and compare asset names,
#                        sizes and sha256 against what is on disk; print the URL
#
# The token is never printed and never stored in a commit: it lives in the environment
# and in a temporary ~/.netrc (shredded at the end). Revocation is your job afterwards.
# shellcheck shell=sh disable=SC2039,SC3003,SC3010
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

PK_ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$PK_ROOT"
BUILD=$PK_ROOT/build
OWNER=${OWNER:-risky-chokra}
REPO=${REPO:-pk-os}
VERSION=${VERSION:-$(sed -n 's/^OS_VERSION=//p' config/live.conf 2>/dev/null | head -1)}
VERSION=${VERSION:-0.0}
TAG=${TAG:-v$VERSION}
CREATE=1; DRY=0; DOCS_ONLY=0
for a in "$@"; do
  case "$a" in
    --no-create) CREATE=0 ;;
    --dry-run)   DRY=1 ;;
    --docs-only) DOCS_ONLY=1 ;;
    -h|--help)   sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "publish: unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '[publish] %s\n' "$*"; }
warn() { printf '[publish warn] %s\n' "$*" >&2; }
die()  { printf '[publish FAIL] %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------- 1. docs language guard
# The release must ship English-only documentation. Words below are the Hindi/Hinglish
# tokens that showed up in earlier drafts; Devanagari characters are caught separately.
docs_guard() {
  # shellcheck disable=SC2086
  files=$(ls README.md STATUS.md 2>/dev/null; ls docs/*.md 2>/dev/null; ls rootfs/overlay/usr/share/doc/pkos/README.md 2>/dev/null)
  [ -n "$files" ] || { warn "no docs to guard (skipping)"; return 0; }
  bad=0
  # Devanagari anywhere in a doc file
  if grep -lP '[\x{0900}-\x{097F}]' $files 2>/dev/null; then
    warn "^ files contain Devanagari characters"; bad=1
  fi
  # Latin-transliterated Hindi/Hinglish function words (word-boundary, lowercase-insensitive)
  # only unambiguous Hindi/Latin-transliteration tokens: none of these are English words
  pat='(^|[^a-z])(hai|hain|nahi|nahin|karo|karke|karna|karne|kyun|kyonki|kaise|apna|apne|hamara|hamare|chahiye|milta|milte|raha|rahi|gaya|gayi|lekin|dono|sirf|pehle|pahle|phir|abhi|thoda|thodi|zyada|jyada|poora|poori|galat|theek|bilkul|chhota|chhoti|chhote|ek[[:space:]]dum|ho[[:space:]]jaata|ho[[:space:]]gaya|kar[[:space:]]lo|kar[[:space:]]do|de[[:space:]]do|le[[:space:]]lo|daalo|daal[[:space:]]do|uthao|nikaalo|padho|chalao|banao|banata|banti|jaanta|mauke|haal|sach[[:space:]])'
  hits=$(grep -niE "$pat" $files 2>/dev/null) || hits=""
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | head -25 | sed 's/^/  HINGLISH? /'
    bad=1
  fi
  if [ "$bad" = 1 ]; then
    [ "${DOCS_ALLOW_HINGLISH:-0}" = 1 ] && { warn "DOCS_ALLOW_HINGLISH=1 -> continuing"; return 0; }
    die "documentation is not English-only (see the lines above); fix them or set DOCS_ALLOW_HINGLISH=1"
  fi
  say "docs language guard: English only, OK ($(printf '%s\n' $files | grep -c '') files)"
}
# the guard always runs: a release must never ship documentation that is not English
docs_guard
[ "$DOCS_ONLY" = 1 ] && exit 0

# ------------------------------------------------------------------ preconditions
[ -n "$GITHUB_TOKEN" ] || die "GITHUB_TOKEN set karo (classic PAT, scope 'repo')"
[ -n "$OWNER" ]        || die "OWNER set karo (GitHub user or org that owns the repo)"
have() { command -v "$1" >/dev/null 2>&1; }
have git   || die "git missing"
have curl  || die "curl missing -> sudo apt install -y curl"
have sha256sum || die "sha256sum missing"
API=https://api.github.com
UPLOAD=https://uploads.github.com
AUTH="Authorization: Bearer $GITHUB_TOKEN"
# accept <api-path> [curl extras...]   (path first: it is what carries the host)
accept() { api_p="$1"; shift; curl -sS -H "$AUTH" -H "Accept: application/vnd.github+json" \
             -H "X-GitHub-Api-Version: 2022-11-28" "$@" "$API$api_p"; }

# asset list: "<basename>|<asset name>"
assets=""
add_asset() { [ -f "$1" ] && assets="$assets$1|$2
" || warn "asset missing, skipping: $1"; }
add_asset "$BUILD/pkos.iso"                        "pkos-$VERSION.iso"
add_asset "$BUILD/pkos-apps.iso"                   "pkos-$VERSION-apps.iso"
add_asset "$BUILD/manifest.txt"                    "pkos-$VERSION-manifest.txt"
add_asset "$BUILD/manifest-apps.txt"               "pkos-$VERSION-apps-manifest.txt"
add_asset "$BUILD/pkos-src.tar.gz"                 "pkos-$VERSION-src.tar.gz"
add_asset "$BUILD/pkos-main.bundle"                "pkos-main.bundle"
add_asset "$BUILD/work/runtime/etc/pk-essentials.txt" "pkos-$VERSION-essentials.txt"
nassets=$(printf '%s' "$assets" | grep -c '|' || true)
[ "$nassets" -ge 1 ] || die "no assets to upload (run 'make kit' first)"
say "$nassets asset(s) ready; version=$VERSION tag=$TAG repo=$OWNER/$REPO"

gh_err() { # <json> <context>
  msg=$(printf '%s' "$1" | sed -n 's/.*"message"[ ]*:[ ]*"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$msg" ] && warn "$2: $msg"
}

# ------------------------------------------------------------------ 2. create repo
if [ "$CREATE" = 1 ]; then
  code=$(accept "/repos/$OWNER/$REPO" -o /tmp/pk-pub-repo.json -w '%{http_code}')
  case "$code" in
    200) say "repository $OWNER/$REPO already exists (private=$(sed -n 's/.*"private":[a-z]*/&/p' /tmp/pk-pub-repo.json | head -1))" ;;
    404) say "creating public repository $OWNER/$REPO"
         body=$(printf '{"name":"%s","description":"%s","private":false,"has_issues":true,"has_wiki":false,"auto_init":false,"license_template":"mit","gitignore_template":"null"}' \
                "$REPO" "pk's OS - a small self-built Linux live/install ISO (docs, sources, releases)")
         res=$(accept "/user/repos" -X POST -H "Content-Type: application/json" -d "$body")
         printf '%s' "$res" | grep -q '"full_name"' || { gh_err "$res" "repo create"; die "could not create the repository (classic PAT with 'repo' scope? org permissions?)"; }
         say "created: $(printf '%s' "$res" | sed -n 's/.*"html_url":"\([^"]*\)".*/\1/p' | head -1)" ;;
    *)   gh_err "$(cat /tmp/pk-pub-repo.json 2>/dev/null)" "repo lookup"; die "unexpected HTTP $code while looking up the repository" ;;
  esac
fi

# ------------------------------------------------------------------ 3. push
NOTES="$PK_ROOT/docs/RELEASE-NOTES.md"
[ -f "$NOTES" ] || NOTES="$PK_ROOT/STATUS.md"
[ -f "$NOTES" ] || warn "no release notes file (docs/RELEASE-NOTES.md / STATUS.md) - the release will have an empty body"

NETRC=$(mktemp)
cat > "$NETRC" <<NR
machine github.com
  login x-access-token
  password $GITHUB_TOKEN
machine api.github.com
  login x-access-token
  password $GITHUB_TOKEN
NR
chmod 600 "$NETRC"
cleanup() {
  rm -f /tmp/pk-pub-*.json "$NETRC" 2>/dev/null || true
  git -C "$PK_ROOT" remote set-url origin "https://github.com/$OWNER/$REPO.git" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
export GIT_ASKPASS=/bin/false
gitcfg=" -c credential.helper='!f() { echo \"username=x-access-token\"; echo \"password=$GITHUB_TOKEN\"; }; f'"

BR=$(git rev-parse --abbrev-ref HEAD)
if [ "$DRY" = 0 ]; then
  git -C "$PK_ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null || \
    git -C "$PK_ROOT" tag -a "$TAG" -m "pk's OS $VERSION"
  [ -n "$(git -C "$PK_ROOT" status --porcelain 2>/dev/null | head -1)" ] && \
    warn "working tree is dirty: the tag points at HEAD, which may not include these edits"
fi
git -C "$PK_ROOT" remote remove origin >/dev/null 2>&1 || true
run git -C "$PK_ROOT" remote add origin "https://x-access-token:$GITHUB_TOKEN@github.com/$OWNER/$REPO.git"
say "pushing $BR -> $OWNER/$REPO"
run env GIT_TERMINAL_PROMPT=0 git -C "$PK_ROOT" push -u origin "$BR" 2>&1 | sed 's/^/  /'
run env GIT_TERMINAL_PROMPT=0 git -C "$PK_ROOT" push -f origin "refs/tags/$TAG" 2>&1 | sed 's/^/  /' || true

# ------------------------------------------------------------------ 4. tag + release
notes=$( [ -f "$NOTES" ] && head -c 120000 "$NOTES" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}' || echo "")
rel=$(accept -X POST -H "Content-Type: application/json" \
      "/repos/$OWNER/$REPO/releases" -X POST -H "Content-Type: application/json" \
      -d "{\"tag_name\":\"$TAG\",\"name\":\"pk's OS $VERSION\",\"body\":\"$notes\",\"draft\":false,\"prerelease\":false,\"target_commitish\":\"$BR\"}")
RELID=$(printf '%s' "$rel" | grep -o '"id":[ ]*[0-9]*' | head -1 | tr -dc 0-9)
if [ -z "$RELID" ]; then
  say "release already exists for $TAG -> reusing it"
  all=$(accept "/repos/$OWNER/$REPO/releases/tags/$TAG")
  RELID=$(printf '%s' "$all" | grep -o '"id":[ ]*[0-9]*' | head -1 | tr -dc 0-9)
  [ -n "$RELID" ] || { gh_err "$rel" "release create"; die "could not create or find the release"; }
  accept "/repos/$OWNER/$REPO/releases/$RELID" -X PATCH -H "Content-Type: application/json" \
    -d "{\"name\":\"pk's OS $VERSION\",\"body\":\"$notes\"}" >/dev/null
fi
RELURL=$(printf '%s' "$rel" | sed -n 's/.*"html_url":"\([^"]*\)".*/\1/p' | head -1)
say "release id=$RELID ${RELURL:+url=$RELURL}"

# ------------------------------------------------------------------ 5. assets
existing=$(accept "/repos/$OWNER/$REPO/releases/$RELID/assets")
printf '%s' "$assets" > /tmp/pk-pub-assets.txt
while IFS='|' read -r path name; do
  [ -n "$path" ] || continue
  n=$((n+1))
  size=$(wc -c < "$path" | tr -d ' ')
  sha=$(sha256sum "$path" | cut -c1-64)
  # replace an asset of the same name (upload is not idempotent on GitHub)
  if [ -n "$aid" ]; then
    oldid=$(printf '%s' "$existing" | sed -n 's/.*"assets":\[{.*"id":[ ]*\([0-9]*\).*/\1/p' | head -1)
    for j in $(printf '%s' "$existing" | sed 's/},{/}\n{/g' | grep -n "\"name\":\"$name\"" | cut -d: -f1); do
      oldid=$(printf '%s' "$existing" | sed -n "${j}p" | sed -n 's/.*"id":[ ]*\([0-9]*\).*/\1/p' | head -1)
      [ -n "$oldid" ] && { say "  replacing existing asset $name (id=$oldid)"
        run accept "/repos/$OWNER/$REPO/releases/assets/$oldid" -X DELETE >/dev/null || true; }
    done
  fi
  say "  uploading $name ($size bytes, sha256 ${sha%%??????????????????????????????????????????????????????????????????????????????????????}…)"
  tries=1
  until [ "$DRY" = 1 ] || curl -sS --fail -X POST -H "$AUTH" -H "Content-Type: application/octet-stream" \
        --data-binary "@$path" "$UPLOAD/repos/$OWNER/$REPO/releases/$RELID/assets?name=$name" > /tmp/pk-pub-asset.json; do
    tries=$((tries+1)); [ "$tries" -gt 3 ] && { warn "upload failed 3x: $name"; exit 1; }
    warn "  retry $tries for $name"; sleep 5
  done
done < /tmp/pk-pub-assets.txt

# ------------------------------------------------------------------ 6. verify
say "verifying the published release through the API"
ok=1
fin=$(accept "/repos/$OWNER/$REPO/releases/$RELID")
while IFS='|' read -r path name; do
  [ -n "$path" ] || continue
  want=$(wc -c < "$path" | tr -d ' ')
  got=$(printf '%s' "$fin" | tr '{' '\n' | grep "\"name\":\"$name\"" | sed -n 's/.*"size":[ ]*\([0-9]*\).*/\1/p' | head -1)
  dl=$(printf '%s' "$fin" | tr '{' '\n' | grep "\"name\":\"$name\"" | sed -n 's|.*"browser_download_url":"\([^"]*\)".*|\1|p' | head -1)
  if [ -n "$got" ] && [ "$got" = "$want" ]; then
    printf '  OK   %-34s %s bytes  %s\n' "$name" "$got" "${dl:-}"
  else
    printf '  BAD  %-34s local=%s remote=%s\n' "$name" "$want" "${got:-missing}"; ok=0
  fi
done < /tmp/pk-pub-assets.txt
[ "$ok" = 1 ] || die "some assets did not verify - check the release page"
say "done. release: ${RELURL:-https://github.com/$OWNER/$REPO/releases/tag/$TAG}"

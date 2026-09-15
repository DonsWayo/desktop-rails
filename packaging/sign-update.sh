#!/bin/bash
# Sign a built update bundle and add it to the manifest the shell fetches.
#
# What tauri-plugin-updater 2.10 actually reads (src/updater.rs, RemoteRelease
# and its hand-written Deserialize):
#
#   {
#     "version": "1.2.0",              # semver, leading v allowed
#     "notes": "...",                  # optional
#     "pub_date": "2026-09-15T10:00:00Z",   # optional, RFC 3339
#     "platforms": {
#       "darwin-aarch64": { "url": "https://...", "signature": "..." }
#     }
#   }
#
# The platform key is `<os>-<arch>`: os is darwin, linux or windows (the plugin
# calls macOS "darwin"), arch is x86_64, aarch64, i686 or armv7. `signature` is
# base64 of the whole .minisig text, which is what --sig writes, and NOT a URL.
#
# The bundle at `url` must be what the plugin knows how to install on that
# platform: a .app.tar.gz on macOS, an .AppImage.tar.gz on Linux, the NSIS or
# MSI installer on Windows. Signing something else produces a manifest that
# verifies and then fails to install.
#
# Usage:
#   packaging/sign-update.sh --artifact dist/Ledger.app.tar.gz \
#     --version 1.2.0 --target darwin-aarch64 \
#     --url https://example.com/releases/1.2.0/Ledger.app.tar.gz
#
# Run it once per platform against the same --manifest to build one manifest
# covering all of them.

set -euo pipefail
cd "$(dirname "$0")/.."
HERE="$PWD/packaging"

ARTIFACT=""; VERSION=""; TARGET=""; URL=""; NOTES=""; NOTES_FILE=""; PUB_DATE=""
KEY="$PWD/.signing/updater.key"; MANIFEST=""; SIG=""; PUBLIC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --artifact)   ARTIFACT="$2"; shift 2 ;;
    --version)    VERSION="$2"; shift 2 ;;
    --target)     TARGET="$2"; shift 2 ;;
    --url)        URL="$2"; shift 2 ;;
    --key)        KEY="$2"; shift 2 ;;
    --public)     PUBLIC="$2"; shift 2 ;;
    --manifest)   MANIFEST="$2"; shift 2 ;;
    --sig)        SIG="$2"; shift 2 ;;
    --notes)      NOTES="$2"; shift 2 ;;
    --notes-file) NOTES_FILE="$2"; shift 2 ;;
    --pub-date)   PUB_DATE="$2"; shift 2 ;;
    -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

command -v node >/dev/null || { echo "node is required (see mise: node)"; exit 1; }

[ -f "$ARTIFACT" ] || { echo "--artifact must be a file"; exit 1; }
[ -n "$VERSION" ]  || { echo "--version is required"; exit 1; }
[ -n "$URL" ]      || { echo "--url is required (where the artifact will be downloaded from)"; exit 1; }

# Caught here rather than at update time, because a manifest with a bad version
# or an unknown platform key looks fine until an installed app silently decides
# there is nothing to update to.
printf '%s' "$VERSION" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)*$' \
  || { echo "--version must be semver, got: $VERSION"; exit 1; }

if [ -z "$TARGET" ]; then
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux)  os=linux ;;
    *)      echo "--target is required on this platform"; exit 1 ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64|amd64)  arch=x86_64 ;;
    *) echo "--target is required: cannot map $(uname -m)"; exit 1 ;;
  esac
  TARGET="$os-$arch"
  echo "  target not given; using this machine's: $TARGET"
fi

printf '%s' "$TARGET" | grep -Eq '^(darwin|linux|windows)-(x86_64|aarch64|i686|armv7)$' \
  || { echo "--target must be <darwin|linux|windows>-<x86_64|aarch64|i686|armv7>, got: $TARGET"; exit 1; }

[ -z "$MANIFEST" ] && MANIFEST="$(dirname "$ARTIFACT")/latest.json"
[ -z "$SIG" ] && SIG="$ARTIFACT.sig"

# CI hands the key over as a secret rather than a file on disk.
if [ -n "${TURBO_DESKTOP_SIGNING_KEY:-}" ]; then
  KEY="$(mktemp)"
  trap 'rm -f "$KEY"' EXIT
  chmod 600 "$KEY"
  printf '%s\n' "$TURBO_DESKTOP_SIGNING_KEY" > "$KEY"
fi

[ -f "$KEY" ] || { echo "No signing key at $KEY — run packaging/generate-key.sh first"; exit 1; }

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

step "Signing $(basename "$ARTIFACT") ($(du -h "$ARTIFACT" | cut -f1))"
node "$HERE/lib/updater-cli.mjs" sign \
  --key "$KEY" --artifact "$ARTIFACT" --sig "$SIG" \
  --password "${TURBO_DESKTOP_SIGNING_PASSWORD:-}" \
  --comment "timestamp:$(date +%s)	file:$(basename "$ARTIFACT")	version:$VERSION	hashed" \
  >/dev/null
echo "  $SIG"

# Verifying here, against the public half, is what catches a wrong password or
# a key that does not match the pubkey already shipped in installed apps —
# before a broken release is published rather than after nobody can update.
[ -z "$PUBLIC" ] && PUBLIC="${KEY%.key}.pub"
if [ -f "$PUBLIC" ]; then
  step "Verifying against $(basename "$PUBLIC")"
  echo "  $(node "$HERE/lib/updater-cli.mjs" verify \
        --public "$PUBLIC" --artifact "$ARTIFACT" --sig "$SIG")"
else
  echo "  no public key beside the secret key; skipping the read-back check"
fi

step "Manifest"
args=(manifest --manifest "$MANIFEST" --version "$VERSION" --target "$TARGET" --url "$URL" --sig "$SIG")
[ -n "$NOTES" ]      && args+=(--notes "$NOTES")
[ -n "$NOTES_FILE" ] && args+=(--notes-file "$NOTES_FILE")
[ -n "$PUB_DATE" ]   && args+=(--pub-date "$PUB_DATE")

PLATFORMS="$(node "$HERE/lib/updater-cli.mjs" "${args[@]}")"
echo "  $MANIFEST"
echo "  version $VERSION for: $PLATFORMS"

step "Publish"
cat <<NEXT
  Upload the artifact so it is reachable at exactly:
    $URL
  Serve the manifest at the URL in this app's "updater.endpoints".
  Both must be https — the plugin refuses plain http in a release build.
NEXT

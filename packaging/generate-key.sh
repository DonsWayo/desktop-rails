#!/bin/bash
# Make the minisign keypair that signs this app's updates.
#
# tauri-plugin-updater verifies every downloaded bundle against a minisign
# public key before it will install it, so an app without a keypair has no
# update path. This needs no Apple certificate and no account anywhere: the
# private half is a file on your disk, and the public half is a string in
# turbo-desktop.config.json.
#
# The private key never goes in git. It is written to .signing/, which
# .gitignore already covers, with mode 0600. Back it up somewhere you would
# keep a password: losing it means no existing installation can ever be
# updated again, because they will only accept bundles signed by this key.
#
# Usage:
#   packaging/generate-key.sh                    # .signing/updater.{key,pub}
#   packaging/generate-key.sh --name ledger      # .signing/ledger.{key,pub}
#   TURBO_DESKTOP_SIGNING_PASSWORD=... packaging/generate-key.sh

set -euo pipefail
cd "$(dirname "$0")/.."
HERE="$PWD/packaging"

NAME="updater"; DIR="$PWD/.signing"; FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name)    NAME="$2"; shift 2 ;;
    --dir)     DIR="$2"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

command -v node >/dev/null || { echo "node is required (see mise: node)"; exit 1; }

SECRET="$DIR/$NAME.key"
PUBLIC="$DIR/$NAME.pub"

# Overwriting a key is the one mistake here that cannot be undone, so it takes
# an explicit --force.
if [ -e "$SECRET" ] && [ "$FORCE" -eq 0 ]; then
  echo "$SECRET already exists."
  echo "Pass --force only if you are certain nothing has shipped signed by it."
  exit 1
fi

mkdir -p "$DIR"
chmod 700 "$DIR"

# The password is read from the environment, never an argument: arguments are
# visible to every process on the machine through ps. An empty one is allowed
# and matches what `tauri signer generate --password ""` produces.
PASSWORD="${TURBO_DESKTOP_SIGNING_PASSWORD:-}"

OUTPUT="$(node "$HERE/lib/updater-cli.mjs" generate \
  --secret "$SECRET" --public "$PUBLIC" \
  --password "$PASSWORD" --comment "turbo-desktop $NAME secret key")"

KEY_ID="$(printf '%s\n' "$OUTPUT" | sed -n '1p')"
PUBKEY="$(printf '%s\n' "$OUTPUT" | sed -n '2p')"

cat <<SUMMARY

  key id      $KEY_ID
  secret key  $SECRET   (mode 0600, never commit this)
  public key  $PUBLIC

Put this in turbo-desktop.config.json — one generic shell binary reads its
updater settings from there, so this is per app, not per build:

  "updater": {
    "endpoints": ["https://example.com/updates/latest.json"],
    "pubkey": "$PUBKEY"
  }

For CI, hand the signing job the secret key and its password as secrets:

  TURBO_DESKTOP_SIGNING_KEY       the contents of $NAME.key
  TURBO_DESKTOP_SIGNING_PASSWORD  the password you just used

SUMMARY

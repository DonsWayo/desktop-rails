#!/bin/bash
# Turn a Rails app plus a relocatable interpreter into a signed, distributable
# macOS .app.
#
# This is the packaging leg the feasibility study said was 60% of the work, in
# one script. Each step here exists because something was measured:
#
#   * The interpreter must be relocatable. A package-manager Ruby links absolute
#     paths from libruby (gmp), openssl and — decisively — psych (libyaml), and
#     Rails will not boot without psych. Build it with --enable-load-relative.
#   * Never `rails server`. railties creates tmp/cache, tmp/pids and tmp/sockets
#     under Rails.root ignoring config.paths, which is EACCES in a read-only
#     bundle. Boot Puma from config.ru instead.
#   * Signing runs inside-out, and the entitlements go on the *interpreter*: the
#     app's main executable is a launcher script and `ruby` is the process that
#     dlopens the extensions.
#
# Usage:
#   packaging/pack.sh --app ../my_rails_app --runtime /path/to/ruby --name "My App"
#
# To ship an app that can update itself, give it the manifest URL and the public
# half of the key that will sign releases (packaging/generate-key.sh):
#
#   --version 1.1.0 \
#   --update-url https://downloads.example.com/ledger/latest.json \
#   --update-key .signing/updater.pub
#
# See AUTO_UPDATE.md. Without these the app simply never looks for an update.

set -euo pipefail
cd "$(dirname "$0")/.."
HERE="$PWD/packaging"

APP_SRC=""; RUNTIME=""; GEMS=""; SHELL_BIN=""; NAME="Turbo Desktop App"
BUNDLE_ID="dev.turbodesktop.app"; IDENTITY="-"; OUT="$PWD/dist"; KEEP_DEV=0
VERSION="1.0"; UPDATE_URL=""; UPDATE_PUBKEY=""; UPDATE_PUBKEY_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --app)       APP_SRC="$2"; shift 2 ;;
    --runtime)   RUNTIME="$2"; shift 2 ;;
    --gems)      GEMS="$2"; shift 2 ;;
    --shell)     SHELL_BIN="$2"; shift 2 ;;
    --name)      NAME="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --identity)  IDENTITY="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --version)   VERSION="$2"; shift 2 ;;
    --update-url) UPDATE_URL="$2"; shift 2 ;;
    --update-key) UPDATE_PUBKEY_FILE="$2"; shift 2 ;;
    --keep-dev)  KEEP_DEV=1; shift ;;
    -h|--help)   sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

[ -d "$APP_SRC" ]            || { echo "--app must be a Rails app directory"; exit 1; }
[ -x "$RUNTIME/bin/ruby" ]   || { echo "--runtime must contain bin/ruby"; exit 1; }
[ -f "$APP_SRC/config.ru" ]  || { echo "$APP_SRC has no config.ru — is it a Rails app?"; exit 1; }

# The updater takes the endpoint and the key together or not at all: an endpoint
# without a key would mean installing whatever that server offered.
if [ -n "$UPDATE_PUBKEY_FILE" ]; then
  [ -f "$UPDATE_PUBKEY_FILE" ] || { echo "--update-key must be a .pub file"; exit 1; }
  command -v node >/dev/null || { echo "node is required to read --update-key"; exit 1; }
  UPDATE_PUBKEY="$(node "$HERE/lib/updater-cli.mjs" pubkey --public "$UPDATE_PUBKEY_FILE")"
fi
if [ -n "$UPDATE_URL" ] && [ -z "$UPDATE_PUBKEY" ]; then
  echo "--update-url needs --update-key: an unsigned update is worse than none"; exit 1
fi
if [ -n "$UPDATE_PUBKEY" ] && [ -z "$UPDATE_URL" ]; then
  echo "--update-key needs --update-url"; exit 1
fi

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
APP="$OUT/$NAME.app"
RES="$APP/Contents/Resources"

step "Assembling $NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$RES"
cp -R "$RUNTIME" "$RES/ruby"
[ -n "$GEMS" ] && [ -d "$GEMS" ] && cp -R "$GEMS" "$RES/gems"
rsync -a --exclude 'tmp/' --exclude 'log/' --exclude '.git/' --exclude 'node_modules/' \
      "$APP_SRC/" "$RES/app/"
echo "  interpreter, gems and app copied"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>__EXECUTABLE__</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <!-- macOS prompts per app bundle for these, whatever language asks. -->
  <key>NSDocumentsFolderUsageDescription</key><string>$NAME needs access to files you open.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>$NAME needs access to files you open.</string>
</dict>
</plist>
PLIST

# With a shell, the bundle's executable is the GUI and the launcher becomes the
# script it spawns. Without one, the bundle is a server with no window — useful
# for testing the packaging, not something to hand a person.
if [ -n "$SHELL_BIN" ]; then
  [ -x "$SHELL_BIN" ] || { echo "--shell must be an executable"; exit 1; }
  cp "$SHELL_BIN" "$APP/Contents/MacOS/$(basename "$SHELL_BIN")"
  SHELL_NAME="$(basename "$SHELL_BIN")"
  echo "  shell embedded: $SHELL_NAME"

  # The updater block is written only when both halves were given: the shell
  # treats a half-filled one as "not configured" anyway, so an empty one in the
  # file would be nothing but noise to read past.
  UPDATER_BLOCK=""
  if [ -n "$UPDATE_URL" ]; then
    UPDATER_BLOCK=$(cat <<UPDATER
,
  "updater": {
    "endpoints": ["$UPDATE_URL"],
    "pubkey": "$UPDATE_PUBKEY",
    "current_version": "$VERSION"
  }
UPDATER
)
    echo "  updates: $UPDATE_URL (v$VERSION)"
  fi

  # The shell runs the bundled interpreter, not a developer's Ruby. Relative to
  # the config, which sits beside it in Resources.
  cat > "$RES/turbo-desktop.config.json" <<CONFIG
{
  "app_name": "$NAME",
  "server_url": "http://127.0.0.1:0",
  "window": { "width": 1100, "height": 800 },
  "server": { "command": "../MacOS/launch", "directory": "." }$UPDATER_BLOCK
}
CONFIG
else
  SHELL_NAME="launch"
fi

cat > "$APP/Contents/MacOS/launch" <<'LAUNCH'
#!/bin/bash
# A signed .app is read-only while Rails expects tmp, log and storage to be
# writable, so everything it writes goes to the OS data directory instead.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$here/Info.plist" 2>/dev/null || echo dev.turbodesktop.app)"

export DESKTOP_DATA_DIR="${DESKTOP_DATA_DIR:-$HOME/Library/Application Support/$id}"
mkdir -p "$DESKTOP_DATA_DIR"/{tmp,log,storage}

export GEM_HOME="$here/Resources/gems"
export GEM_PATH="$GEM_HOME:$(echo "$here"/Resources/ruby/lib/ruby/gems/*)"
export RAILS_ENV="${RAILS_ENV:-production}"
export BUNDLE_GEMFILE="$here/Resources/app/Gemfile"
cd "$here/Resources/app"

# Never `rails server`: railties creates tmp dirs under Rails.root regardless of
# config.paths, which fails in a read-only bundle.
exec "$here/Resources/ruby/bin/ruby" "${@:-boot.rb}"
LAUNCH
chmod +x "$APP/Contents/MacOS/launch"

# Written after the launcher, because the executable depends on whether a shell
# was embedded.
sed -i.bak "s|__EXECUTABLE__|$SHELL_NAME|" "$APP/Contents/Info.plist" && rm -f "$APP/Contents/Info.plist.bak"

cp "$HERE/templates/boot.rb" "$RES/app/boot.rb"

step "Pruning"
KEEP_DEV=$KEEP_DEV "$HERE/prune.sh" "$RES"

step "Signing (identity: $IDENTITY)"
ENTS="$HERE/entitlements.plist"
args=(--force --timestamp=none --options runtime --entitlements "$ENTS" --sign "$IDENTITY")

n=0
while IFS= read -r -d '' f; do
  codesign "${args[@]}" "$f" 2>/dev/null && n=$((n + 1)) || true
done < <(find "$RES" \( -name '*.dylib' -o -name '*.bundle' -o -name '*.so' \) -type f -print0)
codesign "${args[@]}" "$RES/ruby/bin/ruby"
# Everything in MacOS/ counts as code, scripts included. An unsigned launcher
# there makes the bundle signature invalid with "code object is not signed at
# all", which reads like a problem with the binary and is not.
codesign "${args[@]}" "$APP/Contents/MacOS/launch"
if [ -n "$SHELL_BIN" ]; then
  codesign "${args[@]}" "$APP/Contents/MacOS/$SHELL_NAME"
fi
codesign "${args[@]}" "$APP"
echo "  signed $n nested binaries, the interpreter and the bundle"

step "Verifying"
codesign --verify --strict --deep "$APP" && echo "  signature verifies"
printf '  entitlements on the interpreter: %s\n' \
  "$(codesign -d --entitlements - "$RES/ruby/bin/ruby" 2>&1 | grep -oE 'com\.apple\.security\.cs\.[a-z-]+' | sort -u | paste -sd, -)"

step "Result"
printf '  %s  (%s)\n' "$APP" "$(du -sh "$APP" | cut -f1)"

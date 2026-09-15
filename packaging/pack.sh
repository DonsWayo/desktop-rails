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

set -euo pipefail
cd "$(dirname "$0")/.."
HERE="$PWD/packaging"

APP_SRC=""; RUNTIME=""; GEMS=""; NAME="Turbo Desktop App"
BUNDLE_ID="dev.turbodesktop.app"; IDENTITY="-"; OUT="$PWD/dist"; KEEP_DEV=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app)       APP_SRC="$2"; shift 2 ;;
    --runtime)   RUNTIME="$2"; shift 2 ;;
    --gems)      GEMS="$2"; shift 2 ;;
    --name)      NAME="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --identity)  IDENTITY="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --keep-dev)  KEEP_DEV=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

[ -d "$APP_SRC" ]            || { echo "--app must be a Rails app directory"; exit 1; }
[ -x "$RUNTIME/bin/ruby" ]   || { echo "--runtime must contain bin/ruby"; exit 1; }
[ -f "$APP_SRC/config.ru" ]  || { echo "$APP_SRC has no config.ru — is it a Rails app?"; exit 1; }

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
  <key>CFBundleExecutable</key><string>launch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <!-- macOS prompts per app bundle for these, whatever language asks. -->
  <key>NSDocumentsFolderUsageDescription</key><string>$NAME needs access to files you open.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>$NAME needs access to files you open.</string>
</dict>
</plist>
PLIST

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

cat > "$RES/app/boot.rb" <<'BOOT'
# Boot Puma from config.ru on a port the OS picks, and write one line of
# handshake where the shell can read it. See pack.sh for why `rails server` is
# avoided.
require "json"
require "rack"
require "puma"
require "puma/configuration"
require "puma/launcher"

# Keep a private handle on the real stdout, then point $stdout at stderr.
# Everything Puma prints — the banner especially — goes to stderr, and the
# handshake channel stays clean. Doing it here rather than through Puma's
# log_writer keeps this independent of Puma's API, which has moved around.
handshake = $stdout.dup
handshake.sync = true
$stdout.reopen($stderr)

app, _ = Rack::Builder.parse_file(File.expand_path("config.ru", __dir__))

config = Puma::Configuration.new do |c|
  c.bind "tcp://127.0.0.1:0"     # the OS picks, which removes the pick-a-port race
  c.app app
  c.workers 0                    # one process to supervise, and one to reap
  c.threads 1, 5
  c.log_requests false
end

launcher = Puma::Launcher.new(config)

# Puma 8 renamed on_booted to after_booted, and the bound port comes from
# binder.connected_ports — binder.full_urls does not exist. An exception raised
# in this hook is swallowed by Puma's event loop, so it is reported explicitly
# rather than leaving a server running that never announced itself.
hook = launcher.events.respond_to?(:after_booted) ? :after_booted : :on_booted
launcher.events.public_send(hook) do
  begin
    port = launcher.binder.connected_ports.first
    raise "Puma bound no TCP port" unless port
    handshake.puts JSON.generate(protocol: "1.0", url: "http://127.0.0.1:#{port}", pid: Process.pid)
  rescue => e
    warn "[boot] could not announce the server: #{e.class}: #{e.message}"
    Process.exit!(1)
  end
end

# The rule that prevents an orphaned server: exit when the parent closes stdin.
# It is the only layer that survives the parent being force-quit, since no shell
# code runs then. Skipped when stdin is not a pipe, so the bundle stays runnable
# by hand for debugging.
if $stdin.stat.pipe? || !$stdin.tty?
  Thread.new do
    $stdin.read
    Process.exit!(0)
  end
end

launcher.run
BOOT

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
codesign "${args[@]}" "$APP"
echo "  signed $n nested binaries, the interpreter and the bundle"

step "Verifying"
codesign --verify --strict --deep "$APP" && echo "  signature verifies"
printf '  entitlements on the interpreter: %s\n' \
  "$(codesign -d --entitlements - "$RES/ruby/bin/ruby" 2>&1 | grep -oE 'com\.apple\.security\.cs\.[a-z-]+' | sort -u | paste -sd, -)"

step "Result"
printf '  %s  (%s)\n' "$APP" "$(du -sh "$APP" | cut -f1)"

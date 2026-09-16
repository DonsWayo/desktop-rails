#!/bin/bash
# Launch a packaged app by its GUI shell and check what a person would see.
#
# shell_check.sh proves the chain starts and stops: the shell spawns the bundled
# interpreter, learns the address, and reaps it. This asks the next question —
# did the window actually load the app — and, for an app that exercises it, did
# the native bridge work from inside that window in both directions.
#
# Everything is asserted from outside the app: the Rails log and the files the
# app writes into DESKTOP_DATA_DIR, which the caller points at a fresh
# directory so nothing from an earlier run can satisfy a check.
#
# Usage:
#   DESKTOP_DATA_DIR=$(mktemp -d) app_check.sh <shell binary> [checks...]
#
# Checks, run in order after the root page is confirmed:
#   text=STRING        GET / contains STRING
#   path=PATH          GET PATH answers 200 (a model-backed page, say)
#   marker=NAME        DESKTOP_DATA_DIR/native-reports/NAME.json appears, and
#                      reports "ok": true
#   request=PATH       GET PATH answers 200, for a check that is triggered from
#                      outside (the Ruby-to-shell call)
#   unchanged=DIR      nothing was written under DIR while the app ran; used on
#                      the app tree inside the bundle, which is read-only
#
# Deliberately bash rather than Python, for the reason shell_check.sh gives: a
# GUI process launched from python's subprocess aborts in tao on macOS.

set -uo pipefail
SHELL_BIN="${1:?usage: app_check.sh <shell binary> [checks...]}"
shift
DEADLINE="${APP_CHECK_TIMEOUT:-240}"
: "${DESKTOP_DATA_DIR:?set DESKTOP_DATA_DIR to an empty directory}"
export DESKTOP_DATA_DIR

LOG="$(mktemp "${TMPDIR:-/tmp}/app_check.XXXXXX")"
RAILS_LOG="$DESKTOP_DATA_DIR/log/desktop.log"
REPORTS="$DESKTOP_DATA_DIR/native-reports"
STAMP="$(mktemp "${TMPDIR:-/tmp}/app_check_stamp.XXXXXX")"

fail() {
  echo "FAIL  $*"
  echo "      shell log:"
  tail -30 "$LOG" | sed 's/^/        /'
  if [ -f "$RAILS_LOG" ]; then
    echo "      rails log:"
    tail -40 "$RAILS_LOG" | sed 's/^/        /'
  fi
  exit 1
}

RUST_LOG=info "$SHELL_BIN" > "$LOG" 2>&1 &
PID=$!
cleanup() { kill -9 "$PID" 2>/dev/null; }
trap cleanup EXIT

for _ in $(seq 1 "$DEADLINE"); do
  grep -q "listening at" "$LOG" 2>/dev/null && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
URL=$(grep -o "listening at http://[^ ]*" "$LOG" | head -1 | sed 's/listening at //')
[ -n "$URL" ] || fail "the shell never announced a server address within ${DEADLINE}s"
echo "OK    shell announced $URL"

# The window's own request for the root page, before this script has sent any.
# Anything curl does afterwards would satisfy a check on the log, so the log is
# read first and curl is only used once the webview has been seen.
ROOT_DONE=""
for _ in $(seq 1 90); do
  if [ -f "$RAILS_LOG" ] && grep -q 'Started GET "/" for' "$RAILS_LOG"; then
    ROOT_DONE=$(awk '/Started GET "\/" for/{seen=1; next} seen && /Completed [0-9]+/{print; exit}' "$RAILS_LOG")
    [ -n "$ROOT_DONE" ] && break
  fi
  kill -0 "$PID" 2>/dev/null || fail "the shell exited before the window asked for /"
  sleep 1
done
[ -n "$ROOT_DONE" ] || fail "the window never requested / from the app"
echo "$ROOT_DONE" | grep -q "Completed 200" || fail "the window's request for / did not succeed: $ROOT_DONE"
echo "OK    the window loaded / — $(echo "$ROOT_DONE" | sed 's/^ *//' | cut -c1-60)"

for check in "$@"; do
  kind="${check%%=*}"
  value="${check#*=}"
  case "$kind" in
    text)
      BODY=$(curl -s --max-time 20 "$URL/")
      echo "$BODY" | grep -qF "$value" || fail "GET / does not contain '$value'"
      echo "OK    GET / contains '$value'"
      ;;
    path|request)
      CODE=$(curl -s -o "$LOG.body" -w "%{http_code}" --max-time 30 "$URL$value")
      [ "$CODE" = "200" ] || { head -c 2000 "$LOG.body"; echo; fail "GET $value returned $CODE"; }
      echo "OK    GET $value 200"
      ;;
    marker)
      FILE="$REPORTS/$value.json"
      for _ in $(seq 1 90); do
        [ -s "$FILE" ] && break
        kill -0 "$PID" 2>/dev/null || fail "the shell exited while waiting for $FILE"
        sleep 1
      done
      [ -s "$FILE" ] || fail "no $value report in $REPORTS within 90s"
      grep -q '"ok": *true' "$FILE" || { cat "$FILE"; echo; fail "the $value report says it failed"; }
      echo "OK    $value report: $(head -c 300 "$FILE")"
      ;;
    unchanged)
      WRITTEN=$(find "$value" -newer "$STAMP" 2>/dev/null | head -5)
      [ -z "$WRITTEN" ] || fail "the app wrote inside its own read-only tree: $WRITTEN"
      echo "OK    nothing written under $value"
      ;;
    *)
      fail "unknown check '$check'"
      ;;
  esac
done

# SIGKILL, so nothing in the shell gets to tidy up; the server must still go.
kill -9 "$PID" 2>/dev/null
for _ in $(seq 1 10); do
  curl -s -o /dev/null --max-time 3 "$URL/up" 2>/dev/null || break
  sleep 1
done
if curl -s -o /dev/null --max-time 3 "$URL/up" 2>/dev/null; then
  echo "FAIL  the server survived kill -9 of the shell — it would orphan"
  exit 1
fi
echo "OK    server gone after kill -9 of the shell"

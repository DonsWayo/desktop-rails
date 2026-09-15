#!/bin/bash
# Launch a packaged bundle by its GUI shell and hold the whole chain to account.
#
# launch_check.py drives the Ruby launcher directly, which covers the server
# half. This drives the *shell* — what a person double-clicks — and so covers
# what that misses: the shell spawning the bundled interpreter, learning the
# address from its handshake, and reaping it on the way out.
#
# Deliberately bash rather than Python. Launched from python's subprocess the
# app aborts inside tao's did_finish_launching before it starts; launched from a
# shell with stdout redirected to a file it runs normally. A GUI process is
# fussy about how it is started, so this starts it the way that works.

set -uo pipefail
SHELL_BIN="${1:?usage: shell_check.sh <path to the shell binary inside the bundle>}"
DEADLINE="${SHELL_CHECK_TIMEOUT:-240}"
# Outside the bundle, always. Writing anything inside a signed .app breaks the
# seal — "a sealed resource is missing or invalid" — and macOS then refuses to
# launch it. A log written next to the binary made the first run pass and every
# run after it fail silently, which is a test destroying its own subject.
LOG="$(mktemp -t shell_check)"

rm -f "$LOG"
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
if [ -z "$URL" ]; then
  echo "FAIL  the shell never announced a server address within ${DEADLINE}s"
  echo "      last lines:"
  tail -15 "$LOG" | sed 's/^/        /'
  exit 1
fi
echo "OK    shell announced $URL"

CODE=000
for _ in 1 2 3 4 5; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$URL/up" 2>/dev/null)
  [ "$CODE" = "200" ] && break
  sleep 2
done
if [ "$CODE" != "200" ]; then
  echo "FAIL  the announced address returned $CODE for GET /up"
  tail -10 "$LOG" | sed 's/^/        /'
  exit 1
fi
echo "OK    GET /up 200 — the bundled interpreter is serving"

# SIGKILL, so nothing in the shell gets to tidy up. The child must still go,
# because it watches its own stdin rather than trusting a parent.
kill -9 "$PID" 2>/dev/null
for _ in $(seq 1 10); do
  curl -s -o /dev/null --max-time 3 "$URL/up" 2>/dev/null || break
  sleep 1
done
if curl -s -o /dev/null --max-time 3 "$URL/up" 2>/dev/null; then
  echo "FAIL  the server survived kill -9 of the shell — it would orphan"
  exit 1
fi
echo "OK    server gone after kill -9 of the shell — no orphan"

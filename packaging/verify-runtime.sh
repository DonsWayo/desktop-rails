#!/bin/bash
# Does the built interpreter actually relocate, and does it still work?
#
# "It compiled" is not the claim. The claim is that it runs from a path it was
# not built for, with nothing pointing at a package manager.
set -uo pipefail
cd "$(dirname "$0")/.."
RUNTIME="${1:?usage: verify-runtime.sh <ruby prefix>}"
FAIL=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; FAIL=1; }

MOVED="$(mktemp -d)/relocated/ruby"
mkdir -p "$(dirname "$MOVED")"
cp -R "$RUNTIME" "$MOVED"

case "$(uname -s)" in
  Darwin) LDD="otool -L"; PATTERN='/opt/homebrew|/usr/local/(opt|Cellar)' ;;
  *)      LDD="ldd";      PATTERN='/home/linuxbrew|/usr/local/lib/lib(ssl|crypto|yaml)' ;;
esac

BAD=$(find "$MOVED" \( -name '*.so' -o -name '*.bundle' -o -name '*.dylib' -o -name 'ruby' \) -type f 2>/dev/null \
      | while read -r f; do $LDD "$f" 2>/dev/null | grep -E "$PATTERN" | sed "s|^|$(basename "$f"): |"; done)
[ -z "$BAD" ] && pass "nothing links into a package manager" \
               || { bad "package-manager linkage:"; echo "$BAD" | head -5 | sed 's/^/      /'; }

"$MOVED/bin/ruby" -v >/dev/null 2>&1 && pass "runs from the new path" || bad "will not run after being moved"
"$MOVED/bin/ruby" -e 'require "psych"; exit(Psych.load("- 1") == [1] ? 0 : 1)' 2>/dev/null \
  && pass "psych loads and parses — Rails cannot boot without it" || bad "psych failed"
"$MOVED/bin/ruby" -e 'require "openssl"; print OpenSSL::OPENSSL_VERSION' >/dev/null 2>&1 \
  && pass "openssl works ($("$MOVED/bin/ruby" -e 'require "openssl"; print OpenSSL::OPENSSL_VERSION'))" || bad "openssl failed"
"$MOVED/bin/ruby" -e 'require "zlib"; require "json"; require "socket"; require "fiddle"' 2>/dev/null \
  && pass "zlib, json, socket, fiddle all load" || bad "a core extension failed"
"$MOVED/bin/ruby" -e 'exit(RbConfig::CONFIG["prefix"].include?("relocated") ? 0 : 1)' \
  && pass "RbConfig follows the binary (--enable-load-relative works)" || bad "RbConfig still points at the build prefix"

rm -rf "$(dirname "$(dirname "$MOVED")")"
[ "$FAIL" -eq 0 ] && printf '  \033[32mPASS\033[0m\n' || printf '  \033[31mFAIL\033[0m\n'
exit "$FAIL"

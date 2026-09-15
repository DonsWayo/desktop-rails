# Packaging a Rails app as a desktop application

One command turns a Rails app and a relocatable interpreter into a signed,
distributable `.app`.

```bash
packaging/pack.sh \
  --app ../my_rails_app \
  --runtime /path/to/relocatable/ruby \
  --gems /path/to/gems \
  --name "Ledger" --bundle-id dev.example.ledger
```

Every step exists because something was measured, not assumed.

## The interpreter must be built for this

A package-manager Ruby will not relocate. On macOS `libruby` links gmp,
`openssl.bundle` links libssl, and stdlib `psych.bundle` links libyaml — all by
absolute path into `/opt/homebrew`. Rails cannot boot without psych, so the
copied-interpreter approach fails on any path. Build it with
`--enable-load-relative` against statically linked dependencies.

## Never `rails server`

`railties .../commands/server/server_command.rb:70` creates `tmp/cache`,
`tmp/pids` and `tmp/sockets` under `Rails.root` without consulting
`config.paths`. In a read-only bundle that is `Errno::EACCES`. The generated
`boot.rb` starts Puma from `config.ru` instead, which sidesteps it entirely.

## Writable state goes to the OS data directory

A signed `.app` is read-only. The launcher points `DESKTOP_DATA_DIR` at
`~/Library/Application Support/<bundle id>` and creates `tmp`, `log` and
`storage` there. Verified: Rails boots and serves with the whole bundle `a-w`.

## The handshake

`boot.rb` binds `127.0.0.1:0`, lets the OS choose the port, and writes one line
to stdout:

```json
{"protocol":"1.0","url":"http://127.0.0.1:58747","pid":95489}
```

Binding port zero and reporting back removes the pick-a-port race that comes
from probing for a free port and then binding it.

Two details that cost time to find:

- **Puma's banner would pollute the channel.** `quiet` does not stop it, because
  it comes from the log writer. `boot.rb` keeps a private `dup` of the real
  stdout and points `$stdout` at stderr, which is independent of Puma's API.
- **`binder.full_urls` does not exist in Puma 8.** The bound port comes from
  `binder.connected_ports`. An exception inside the boot hook is swallowed by
  Puma's event loop, so the hook reports failure explicitly instead of leaving a
  server running that never announced itself.

## Exit when stdin closes

The one rule that prevents an orphaned server. Tauri's process kill signals only
the direct child — no process group, no job object — so nothing runs if the
shell is force-quit. A watchdog thread reading stdin is the only layer that
survives it. Measured: the server exits about 0.2s after EOF.

## Pruning

A shipped bundle carries a lot only a build machine needs.

| Removed | Size |
|---|---|
| Static archives (`.a`) | 24 MB |
| `.gem` cache | 19 MB |
| Debug symbols (`dSYM`) | 6.9 MB |
| Generated docs (`ri`, `rdoc`) | 5.9 MB |
| `ruby/include` | 1.9 MB |
| Gem test suites | small |
| Stripped symbols from 135 binaries | — |

**182 MB → 118 MB, a 35% saving**, and the app is booted afterwards to prove it
still works.

One trap: deleting every directory named `test` also deletes `rack-test`'s
`lib/rack/test/`, which is library code, and the app then fails to boot. Pruning
only touches `test`, `spec` and `features` at each gem's root.

## Signing

Inside-out, never `--deep`, which is deprecated and signs in the wrong order.
All nested `.bundle` and `.dylib` files first, then the interpreter, then the
bundle.

**The entitlements go on the interpreter, not the app.** The app's main
executable is a launcher script, which cannot carry them, and `ruby` is the
process that `dlopen`s the extensions.

Both are required, and they fail differently: without
`disable-library-validation` the `dlopen` is refused, and without
`allow-unsigned-executable-memory` the kernel kills the process outright.

⚠️ Ad-hoc signing gives every binary a different Team ID, which is exactly what
library validation rejects. A real Developer ID signs them all under one team,
so `disable-library-validation` may not be needed with a real certificate.
Re-check with a real identity before shipping.

## Verified end to end

```
182M -> 118M (saved 64M)
signature verifies
handshake: http://127.0.0.1:58747  pid=95489
  GET /up -> 200
exited cleanly 0.2s after stdin closed
```

## Not yet done

Notarization, which needs a real Developer ID. A DMG. Gatekeeper on a
quarantined download. Linux and Windows equivalents of this script.

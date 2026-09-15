# The control channel — native capabilities, called from Ruby

The bridge runs page-to-shell. That is the right shape on mobile, where Hotwire
Native has no server to talk to. A desktop app is different: its server runs in
the same process tree, so Ruby can have a channel of its own.

Without one, every native call has to be bounced off a page — and a background
job cannot raise a notification while no page is open, which is exactly when it
wants to.

```ruby
TurboDesktop::Native.notify(title: "Export finished", body: "invoice.pdf")
TurboDesktop::Native.call("window", "resize", width: 1200, height: 900)
text = TurboDesktop::Native.clipboard_read
```

## How it works

The shell opens a loopback listener on a port the OS picks, generates a token,
and hands both to the app server as **one line of JSON on its stdin**:

```json
{"protocol":"1.0","control":"http://127.0.0.1:52341","token":"…","header":"x-desktop-token"}
```

Ruby reads that line at boot (a Rails initializer in the engine) and posts bridge
messages to it:

```
POST /invoke
X-Desktop-Token: <token>
{"component":"notification","event":"show","data":{"title":"Done"}}
```

The shell routes it to the same component that serves the page. `bridge.rs` now
has a `dispatch` function for that: the command from the page checks the calling
origin, the control channel checks the token, and both end at the same place.

## Why stdin

The token travels on stdin rather than in the environment or on the command
line, so another process on the machine cannot read it out of `ps`. Neutralino
does the same thing for the same reason.

It also does double duty. The shell holds the pipe open for the child's
lifetime, so closing it is the signal to exit — and that is the only layer that
survives the shell being force-quit, since no Rust code runs then. Measured: a
backend watching stdin exits about 0.2s after EOF.

**Exactly one line is consumed.** The handshake reader takes its line and leaves
the rest of the stream alone, so the exit watchdog still works.

## Security

Three things, none of them optional.

- **Loopback only.** The listener binds `127.0.0.1` on a port the OS picks.
- **A real token.** 32 bytes from OS entropy, hex encoded. Deliberately *not*
  the `uuid_simple()` used for window labels, which is a nanosecond counter:
  fine for a label, guessable as a credential.
- **Constant-time comparison**, so a wrong token cannot be discovered a byte at
  a time.

Requests that are not `POST /invoke` are refused, `Content-Length` is bounded so
a malformed header cannot make the shell allocate without limit, and a
malformed body is rejected before it reaches a component.

## On the web, it is a no-op

The same Rails app serves the browser, where there is no shell and no handshake.
There `available?` is false and calls return `nil` rather than raising, so the
same code runs in both places without a guard at every call site.

A shell that should be there but is not answering raises
`TurboDesktop::Native::Error` with the address it tried, because that is a
genuine fault rather than a normal condition.

## Tested

- **Rust**, 6 tests: token length and uniqueness, constant-time comparison,
  header parsing whatever the casing, a missing token parsing as empty rather
  than matching, a malformed `Content-Length` neither panicking nor allocating,
  and only `POST /invoke` routing to the dispatcher.
- **Ruby**, 10 tests: unavailable without a handshake, calls as a no-op on the
  web, the handshake parsed, **exactly one line of stdin consumed**, a
  non-handshake line ignored so a developer running `rails server` by hand still
  boots, messages arriving with the right component and payload, reply values
  coming back, a wrong token refused, and a clear error when nothing answers.

## Not yet done

The Rust listener is unit-tested at the parsing and token layer, but no test
drives the real listener end to end, because that needs a running Tauri app.
The Ruby tests run against a stub that matches `control.rs` by hand, which would
not catch the two drifting apart.

# Auto-update

An installed app asks a URL what the newest version is, downloads the bundle it
names, checks it against a key it has carried since it was built, and replaces
itself. `tauri-plugin-updater` does all of that; what follows is the two things
it needs that are yours — a keypair and a manifest — and how this fork hands it
settings that belong to the app rather than to the shell.

This needs no Apple certificate. Signing an update and signing an application
are unrelated: the key below proves *this build came from you*, and nothing
about it involves Gatekeeper.

```bash
packaging/generate-key.sh                       # once, ever
packaging/sign-update.sh --artifact dist/Ledger.app.tar.gz \
  --version 1.2.0 --target darwin-aarch64 \
  --url https://downloads.example.com/1.2.0/Ledger.app.tar.gz
```

## The key

`packaging/generate-key.sh` writes a minisign keypair to `.signing/`, which
`.gitignore` already covers. The secret half is mode 0600 and never leaves that
directory; the public half is a string you paste into
`turbo-desktop.config.json`.

```
.signing/updater.key    private. never commit. back this up.
.signing/updater.pub    public. safe to publish.
```

A password is read from `TURBO_DESKTOP_SIGNING_PASSWORD`, never from an
argument, because arguments are visible to every process on the machine. An
empty password is allowed and matches what `tauri signer generate --password ""`
produces.

**Losing the secret key ends updates for every copy already installed.** Those
copies will only accept bundles signed by it, and there is no way to tell them
about a new one except by having someone download a fresh install by hand. Back
it up the way you would back up a password.

There is no `minisign` binary and no `tauri signer` on a machine that can
otherwise build this project, and `cargo install tauri-cli` is a long build for
one subcommand. So the keypair is made in Node, which has Ed25519 and BLAKE2b
natively — `packaging/lib/minisign.mjs`, no dependencies. The files it writes
are ordinary minisign files: `minisign -Vm` and `tauri signer sign` both work on
them, and a key made by either of those works here.

## The manifest

`packaging/sign-update.sh` signs a bundle and merges it into `latest.json`. Run
it once per platform against the same `--manifest` and you get one file covering
all of them.

```json
{
  "version": "1.2.0",
  "notes": "What changed",
  "pub_date": "2026-09-15T10:00:00Z",
  "platforms": {
    "darwin-aarch64": {
      "url": "https://downloads.example.com/1.2.0/Ledger.app.tar.gz",
      "signature": "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9t..."
    }
  }
}
```

Four things about this are easy to get wrong, and all four fail quietly:

- **`signature` is the signature itself**, not a URL to a `.sig` file. It is
  base64 of the whole `.minisig` text, because the plugin base64-decodes it and
  then parses minisign text out of the result
  (`tauri-plugin-updater` 2.10, `updater.rs`, `verify_signature`). The same is
  true of `pubkey` in your config.
- **The platform key is `<os>-<arch>`**, where os is `darwin`, `linux` or
  `windows` — the plugin calls macOS "darwin", not "macos" — and arch is
  `x86_64`, `aarch64`, `i686` or `armv7`. A key the running app does not
  recognise reads as "no update available".
- **`version` must be semver** and applies to the whole release. `sign-update.sh`
  refuses to add a second version to a manifest that already has one, because a
  manifest carrying two would hand some users the wrong build.
- **Everything must be https.** The plugin refuses plain http endpoints in a
  release build — and only in a release build, so an http endpoint works all the
  way through development and then fails in the thing you ship.

What you upload has to be what the plugin knows how to install:
`.app.tar.gz` on macOS, `.AppImage.tar.gz` on Linux, the NSIS or MSI installer
on Windows. Signing anything else produces a manifest that verifies and then
fails to install.

## Where the settings live

Not in `tauri.conf.json`. That file is compiled into the shell binary, and this
fork ships **one** shell binary for every app built with it — the whole point of
`turbo-desktop.config.json`. An update endpoint and a signing key belong to the
app, so they go there:

```json
{
  "app_name": "Ledger",
  "server_url": "http://127.0.0.1:0",
  "updater": {
    "endpoints": ["https://downloads.example.com/ledger/latest.json"],
    "pubkey": "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6...",
    "current_version": "1.1.0"
  }
}
```

`src-tauri/src/updater_bridge.rs` reads these and applies them to
`UpdaterBuilder`, which accepts both at runtime. `tauri.conf.json` keeps
`"pubkey": ""` and `"endpoints": []` on purpose; a test fails if either is
filled in, because a key there would appear to work right up until a second app
is built from the same binary.

`current_version` is the version this installation actually is. Without it the
plugin compares releases against the *shell's* crate version, which is the
framework's, so every app would be asking whether there is something newer than
`0.2.1`. Set it to the version the manifest will carry when the app ships.

Leaving out the `updater` block, or either of its two required fields, turns
updating off rather than failing — plenty of apps are installed by other means
and should not be contacting an update server at all. The web layer sees that as
`{ status: "not_configured" }`.

## From the web layer

```js
const result = await TurboDesktop.updater.check();
// { status: "available", version, body, date, current_version }
// { status: "up_to_date" } | { status: "not_configured" } | { status: "error", error }

if (result.status === "available") {
  await TurboDesktop.updater.downloadAndInstall();
}
```

The signature is checked against the configured key before anything is unpacked.
A bundle that fails arrives as `{ status: "error" }` and nothing is written.

## In CI

Give the signing job the key and its password as secrets. `sign-update.sh` picks
the key up from the environment when it is there, writing it to a temporary file
it removes on exit:

```yaml
env:
  TURBO_DESKTOP_SIGNING_KEY: ${{ secrets.UPDATER_SIGNING_KEY }}
  TURBO_DESKTOP_SIGNING_PASSWORD: ${{ secrets.UPDATER_SIGNING_PASSWORD }}
```

It also verifies each signature against the public key before writing the
manifest. That is what catches a wrong password or the wrong key entirely —
before a release is published, rather than after nobody can update.

## How the format is held to

A signer and a verifier written from the same reading of a format will agree
with each other whether or not the reading was right. So the signer here is
checked against something that did not come from it:

- `src-tauri/tests/updater_signature.rs` verifies with `minisign-verify`, the
  crate `tauri-plugin-updater` itself calls, through the same steps its
  `verify_signature` takes. It checks both a committed fixture and an artifact
  signed by the current code, and that a tampered, truncated or
  differently-signed artifact is refused.
- `test/updater-signing.test.js` re-reads the bytes of a fresh signature against
  the layout in `minisign-verify`'s source and checks them with Node's own
  Ed25519, rather than calling the library under test.

The 32-byte BLAKE2b in `packaging/lib/blake2b.mjs` exists because Node only
exposes the 64-byte one and minisign's secret key checksum needs the other. Its
64-byte output is held against Node's native `blake2b512`, which exercises the
same compression function.

## What has not been done

An update has not been watched to apply end to end. Everything up to the moment
of install is exercised: keys, signing, the manifest, and verification by the
crate that does the verifying in the shipped app. What has not been proved is
the last step — a running packaged app fetching a manifest over https,
downloading a bundle, replacing itself and relaunching — because that needs a
Tauri-bundled `.app` (the plugin locates what to replace from the running
executable's bundle layout), an https host, and two signed releases.

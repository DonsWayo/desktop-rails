# Distributing a Desktop Rails app

Desktop Rails apps are [Tauri](https://tauri.app) apps, so distribution means producing native
installers per OS. This guide covers the easy path (a release workflow), local builds, and the
optional-but-recommended signing/update setup.

## TL;DR — build installers from the Actions tab

This repo ships [`.github/workflows/release.yml`](../.github/workflows/release.yml). Run it from
**Actions → Release → Run workflow**.

It used to run on every `v*` tag. Those tags now belong to
[`release-prebuilt.yml`](../.github/workflows/release-prebuilt.yml), which publishes the prebuilt
interpreter and shell that `bin/rails desktop:runtime` and `desktop:shell` download (see
[`packaging/README.md`](../packaging/README.md#prebuilt-releases)); two workflows creating a release
for the same tag would race.

CI builds on three runners (Tauri can't cross-compile) and attaches installers to a **draft
GitHub Release** for you to review and publish:

| Platform | You get |
|----------|---------|
| macOS (universal) | `.dmg` + `.app` (runs on Intel **and** Apple Silicon) |
| Windows | `.msi` + NSIS `.exe` |
| Linux | `.deb` + `.AppImage` |

## What ships inside the app

Desktop Rails follows the Hotwire Native model: the shell loads `server_url` from
`desktop-rails.config.json`, baked in at build time. So a distributed app is a **thin native shell
pointing at your hosted Rails app** — you ship the binary, your Rails app is the product. Set
`server_url` to your production URL before building for release.

## Building locally (to test a bundle)

```bash
npm run build                    # cargo tauri build — bundles for the current OS
npm run build:apple-silicon      # arm64 macOS only
```
Output: `src-tauri/target/release/bundle/`.

## Using this in your own app

`npx desktop-rails new myapp` scaffolds a `desktop/` project. To get the same one-tag releases,
copy `release.yml` into your app's `.github/workflows/` and adjust `projectPath` if your Tauri
project isn't at the repo root. Everything else (matrix, deps, draft release) works as-is.

## Signing & notarization (recommended before shipping to real users)

Unsigned builds trigger Gatekeeper (macOS) and SmartScreen (Windows) warnings. Builds are **unsigned
by default** so a first release just works. To sign, **uncomment the signing block** in
`release.yml` and set the matching repo **secrets** (don't leave the env set to empty secrets — an
empty `APPLE_CERTIFICATE` makes Tauri try, and fail, to import an empty certificate).

- **macOS** (Apple Developer ID + notarization): `APPLE_CERTIFICATE`,
  `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_PASSWORD`,
  `APPLE_TEAM_ID`.
- **Windows** (Authenticode): configure `bundle.windows.certificateThumbprint` (or a signing
  command) in `tauri.conf.json`.

See the Tauri signing guides: [macOS](https://tauri.app/distribute/sign/macos/) ·
[Windows](https://tauri.app/distribute/sign/windows/).

## Auto-update (optional)

`tauri.conf.json` includes the `updater` plugin, but `endpoints` and `pubkey` are empty — updates
are **off** until you configure them:

1. Generate a keypair: `npx tauri signer generate`.
2. Put the public key in `tauri.conf.json` → `plugins.updater.pubkey` and add your update-server
   `endpoints`.
3. Add the private key + password as the `TAURI_SIGNING_PRIVATE_KEY` /
   `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` secrets (the release workflow already passes them through).

Details: [Tauri updater](https://tauri.app/plugin/updater/).

## Status

- ✅ Cross-OS installers via one tag (this workflow).
- ⚙️ Signing / notarization — opt-in (uncomment the block + supply certs).
- ⚙️ Auto-update — plugin present, endpoints/keys not yet configured.

---

More at the official site: **[desktop-rails.dev](https://desktop-rails.dev/)**.

# Distributing a desktop-rails app

There are two things you might distribute, and they are built differently.

| You are shipping | Built by | Guide |
|---|---|---|
| A **bundled** app: your Rails app with its own Ruby | `bin/rails desktop:package` | [README quick start](../README.md#quick-start), [packaging/README.md](../packaging/README.md) |
| A **hosted** app: the prebuilt shell and a config, opening a server you run | `bin/rails desktop:package:hosted` | [README hosted mode](../README.md#wrapping-a-server-you-run-yourself) |
| The **shell alone**, built from source | `cargo tauri build`, or the Release workflow | this page |

## A bundled app

`bin/rails desktop:package` writes the bundle to `.desktop-rails/dist/`: a `.app`
on macOS, a directory tree on Linux, and a directory plus a zip of it on Windows.
There is no installer step; the bundle is what you hand out.

- **macOS.** The bundle is signed ad hoc, which Gatekeeper rejects on anyone
  else's Mac. [packaging/DISTRIBUTION.md](../packaging/DISTRIBUTION.md) has the
  measurements, what a Developer ID and notarisation involve, and
  `packaging/dmg.sh` for a disk image.
- **Updates.** An `updater` block in `desktop-rails.config.json` points the app at
  a signed manifest. [packaging/AUTO_UPDATE.md](../packaging/AUTO_UPDATE.md)
  covers the key and the manifest.

## The shell alone, for hosted mode

In hosted mode the app is a native window pointing at the `server_url` in
`desktop-rails.config.json`, which is bundled with the shell at build time. You
ship the window; your Rails app stays on your server. Set `server_url` to your
production URL before building.

Most apps do not need to build the shell for this: `bin/rails desktop:package:hosted`
puts the prebuilt shell and your config into a signed `.app`, a Linux tree and
tarball, or a Windows directory and zip, with no Rust involved. The rest of this
section is for building installers of the shell itself.

### From the Actions tab

[`.github/workflows/release.yml`](../.github/workflows/release.yml) builds
installers of the shell and attaches them to a **draft GitHub Release** for you
to review and publish. It runs from **Actions → Release → Run workflow** only.

It used to run on every `v*` tag. Those tags now belong to
[`release-prebuilt.yml`](../.github/workflows/release-prebuilt.yml), which
publishes the prebuilt interpreter and shell that `bin/rails desktop:runtime`
and `desktop:shell` download (see
[`packaging/README.md`](../packaging/README.md#prebuilt-releases)); two workflows
creating a release for the same tag would race.

Tauri cannot cross-compile, so each platform builds on its own runner:

| Platform | You get |
|----------|---------|
| macOS (universal) | `.dmg` + `.app` (runs on Intel **and** Apple Silicon) |
| Windows | `.msi` + NSIS `.exe` |
| Linux | `.deb` + `.AppImage` |

### Locally

```bash
npm run build                    # cargo tauri build, for the current OS
npm run build:apple-silicon      # arm64 macOS only
```

Output: `src-tauri/target/release/bundle/`, or
`src-tauri/target/<target>/release/bundle/` for a build with `--target`.

### In your own app

The CLI scaffolds a `desktop/` shell project inside a Rails app. It is not on npm,
so run it from GitHub:

```bash
npx github:DonsWayo/desktop-rails init .
```

To build installers the same way, copy `release.yml` into your app's
`.github/workflows/` and set tauri-action's `projectPath` to `desktop`.

### Signing and notarisation

Unsigned builds trigger Gatekeeper (macOS) and SmartScreen (Windows) warnings,
and on current macOS Gatekeeper refuses them outright (see
[packaging/DISTRIBUTION.md](../packaging/DISTRIBUTION.md)). Builds are **unsigned
by default**. To sign, **uncomment the signing block** in `release.yml` and set
the matching repository **secrets**. Do not leave the variables set to empty
secrets: an empty `APPLE_CERTIFICATE` makes Tauri try, and fail, to import an
empty certificate.

- **macOS** (Developer ID + notarisation): `APPLE_CERTIFICATE`,
  `APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`,
  `APPLE_PASSWORD`, `APPLE_TEAM_ID`.
- **Windows** (Authenticode): configure `bundle.windows.certificateThumbprint`
  (or a signing command) in `tauri.conf.json`.

See the Tauri signing guides: [macOS](https://tauri.app/distribute/sign/macos/) ·
[Windows](https://tauri.app/distribute/sign/windows/).

### Auto-update

The updater plugin is compiled in, and off until the app's
`desktop-rails.config.json` has an `updater` block with `endpoints` and `pubkey`.
They live there rather than in `tauri.conf.json` because one shell binary serves
every app. The key, the manifest and signing an update with
`packaging/sign-update.sh`: [packaging/AUTO_UPDATE.md](../packaging/AUTO_UPDATE.md).

## Status

- Shell installers for all three platforms from the Release workflow, run by hand.
- Signing and notarisation: opt-in, and not yet tested with a Developer ID.
- Auto-update: works once an app configures `updater`; nothing is configured by
  default.

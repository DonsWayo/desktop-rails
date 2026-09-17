# Changelog

## Unreleased

### Security — breaking

A page the window loads is code the shell does not control: in hosted mode it
is a production website, and an XSS on it must not become code execution or
file access on the machines running the app. So everything that reaches the
machine is now off until `desktop-rails.config.json` turns it on, and only the
configured origin can call the bridge at all. These need the 0.3.0.pre3 shell or
later; the prebuilt shells of pre1 and pre2 still have the old defaults.

- **The `shell` component is off by default.** It used to run any command a
  page sent, through a login shell. Enable it with
  `"shell": { "enabled": true, "allowed_commands": ["git status"] }`. The
  command line must be covered by an entry (whole, or as a prefix up to a word
  boundary, like `sudo`), the command may carry no shell metacharacters,
  environment variables a page sets must be listed in `allowed_env`, and a
  `cwd` must be inside the filesystem scope. Apps that spawn processes from
  JavaScript need this block, or every call now fails with "The shell bridge is
  disabled".
- **The `filesystem` component has no default root.** An empty
  `allowed_roots` used to mean the app data directory, which on Linux is also
  where the webview keeps the app's cookies and local storage. It now means
  only what the user picked in a dialog or dropped on a window. Write
  `"allowed_roots": ["$APP_DATA"]` to keep the old behaviour.
- **Reading the clipboard is off by default.** A browser only hands a page the
  clipboard on a paste the user makes. Enable `clipboard.readText()` with
  `"clipboard": { "read": true }`. Writing is unchanged.
- **Only the configured origin may call the shell's commands, judged by the
  frame that sent the request.** `capabilities/main.json` used to admit every
  `https://` origin and every loopback port, including to plugin commands, and
  the origin check looked only at the page the webview was showing. The static
  capability now covers the bundled pages alone; the app origin is granted at
  runtime (and a bundled server's announced address when it announces it), so
  an iframe of another origin, a page reached through `navigation.internal_hosts`,
  an `http://` downgrade of an `https://` app and lookalike hosts are refused
  before any command runs. Remote pages can no longer call plugin commands
  (`plugin:dialog|…`, `plugin:notification|…`, `plugin:shell|open`, the updater's
  JS API) directly. `desktop-rails.js` never did; code that called
  `__TAURI_INTERNALS__.invoke("plugin:…")` from a page has to go through the
  bridge instead.

### Changed

- The build-machine tooling is Ruby and ships in the gem, as
  `desktop-rails-tool` (`DesktopRails::Tooling`): `runtime build`,
  `runtime verify`, `runtime fetch-windows`, `prune`, `dmg`, `notarize`,
  `updater generate-key`, `updater sign` and the CI `smoke` checks. It replaces
  `build-runtime.sh`, `verify-runtime.sh`, `fetch-windows-runtime.ps1`,
  `prune.sh`, `prune.ps1`, `dmg.sh`, `notarize.sh`, `generate-key.sh`,
  `sign-update.sh` and the `packaging/smoke` scripts, whose bash and PowerShell
  copies had drifted apart. `desktop:runtime` no longer needs a checkout of the
  repository, and Windows downloads get the same relocation check as macOS and
  Linux. `gem.sh` and the unpublished `desktop-rails-runtime` gem are gone.
  `notarize` now also re-signs everything in `Contents/MacOS`.
- The runtime a release ships is Ruby 4.0.7: built against OpenSSL 4.0.2 and
  libyaml 0.2.5 on macOS and Linux, and RubyInstaller 4.0.7-1 on Windows. The
  build confines pkg-config to the vendored libraries with
  `PKG_CONFIG_LIBDIR`; clearing `PKG_CONFIG_PATH` alone let psych link
  Homebrew's libyaml.

- The default app id is `dev.desktop-rails.<app>` instead of
  `dev.turbodesktop.<app>`. The app id names the data directory, so an app
  that relied on the default and already has users should set `config.app_id`
  to its old value.

- Renamed from Turbo Desktop to desktop-rails. The gem is `desktop-rails`, the
  module is `DesktopRails`, the generator is `desktop_rails:install`, the CLI is
  `desktop-rails`, and environment variables start with `DESKTOP_RAILS_`. This
  fork of aguspe/turbo_desktop continues as its own project; the MIT notices of
  the original author are kept.
- Version 0.3.0.pre3 (Cargo and npm: 0.3.0-pre.3): Ruby 4.0.7 runtimes with
  OpenSSL 4.0.2 (Windows: RubyInstaller 4.0.7-1), and the shell with secure
  defaults for remote origins. 0.3.0.pre2 before it: the 0.3.0.pre1 shell
  panics on Linux without a tray library and fetches its path configuration
  from port 0; pre2 is the first release carrying both fixes.
- `release.yml`, which builds installers of the bare shell, runs from the
  Actions tab only. `v*` tags belong to `release-prebuilt.yml`, and two
  workflows creating a release for one tag would race.
- `release-runtimes.yml` is now `release-prebuilt.yml`. Its `runtime-v*` tags
  and `desktop-rails-runtime` platform gems are gone: that gem was never
  published, and the missing-runtime message no longer suggests
  `bundle add desktop-rails-runtime`.
- Rails 7.0, 7.1 and 7.2 are proven, not just allowed: `fresh-app.yml` runs the
  quick start on macOS and Linux for the latest patch of 7.0, 7.1, 7.2 and 8.1
  and opens each app's window. The gemspec floor stays at 7.0.
- The install generator ends with the packaging steps of the README's quick
  start and a pointer to hosted mode, instead of `npx desktop-rails init` and
  `dev`, which named a package that is not on npm.
- The CLI describes itself as the shell for hosted mode, says it is not on npm
  and how to run it, and no longer calls itself "Turbo Native for Desktop".

### Removed

- `site/` and `docs/index.html`, upstream's marketing site and documentation
  page. Neither is served for this repository, and both described the old
  hosted-only flow: `gem "desktop-rails"` from RubyGems, `npx desktop-rails`,
  and a 5–10 MB app. The README is the documentation.

### Added

- **Notifications, the badge, global shortcuts and menu items actually work.**
  Before this, the `notification`, `badge`, `shortcut` and `menu-item`
  components emitted Rust events nothing listened to and answered "shown" or
  "registered" anyway. Now:
  - `notification` goes to the platform's notification service
    (`org.freedesktop.Notifications` on Linux, a toast on Windows,
    `NSUserNotificationCenter` on macOS under the running bundle's id). With no
    service, or from a macOS process not running from its `.app`, it is an
    error rather than success. A click (Linux, Windows) focuses the window and
    dispatches `desktop-rails:notification-click`. `DesktopRails::Native.notify`
    takes an `id:` and raises `CallFailed` when nothing was shown;
    `Native.notification_permission` is new.
  - `badge` sets the Dock count or label on macOS and the launcher count on
    Linux (the Unity `LauncherEntry` signal), and answers `supported: false` on
    Windows, which has none. `Native.badge_label` and `Native.clear_badge` are
    new.
  - `shortcut` registers real global shortcuts by id. Re-registering after a
    reload is `alreadyRegistered`, not a second grab; a combination another id,
    the summon shortcut or another application holds is refused with the
    reason; combinations need a non-Shift modifier and pages hold at most 20.
    Firing dispatches `desktop-rails:shortcut`.
  - `"shortcuts": { "summon": "CmdOrCtrl+Shift+Space" }` in the config brings
    the window forward from anywhere with no page code, for hosted apps.
    `desktop:package:hosted` accepts the new `notifications` and `shortcuts`
    keys, checks the summon combination, and lists both in its capability
    summary.
  - `menu-item` adds items to the menu bar, idempotent by id, refusing
    accelerators the app menu or another item uses. Clicks dispatch
    `desktop-rails:menu-item`.
  - `DesktopRails.notifications`, `.notify`, `.badge`, `.shortcuts`, `.menu`
    and `.invokeBridge` in the page API; these reject with the shell's reason
    instead of resolving to `null`.
  - Notifications and page shortcuts are on for the app origin and its Ruby by
    default, and `"notifications": { "enabled": false }` or
    `"shortcuts": { "enabled": false }` turns them off. The plugins' own
    commands (`plugin:global-shortcut|…`, `plugin:notification|…`) stay
    unreachable from every remote page, the app's included.
  - `native-features.yml` proves it from outside the app: on Linux a
    notification service on a session bus records what arrived, xdotool presses
    the keys, and focus is read back from the X server; on macOS what a runner
    can observe.
- Older payloads keep working: `notification` events `connect`/`notify`,
  `shortcut` data `keys`/`shortcut`, `menu-item` data `shortcut`. A `shortcut`
  or `menu-item` registration now needs an `id`.
- `bin/rails desktop:package:hosted` packages a window onto a server you
  already run: the prebuilt shell (`desktop:shell`) and
  `config/desktop-rails.config.json` (or `DESKTOP_RAILS_CONFIG`, with
  `DESKTOP_RAILS_SERVER_URL` replacing `server_url`), laid out as a signed
  macOS `.app`, a Linux tree plus tarball, or a Windows directory plus zip. No
  Rust and no Ruby inside. The config is refused for plain http off loopback, a
  `server.command`, half an updater block, or an unknown key, and what it opens
  is printed before building. `DESKTOP_RAILS_ICON` sets the icon on macOS and
  Linux.
- `DesktopRails::Packager`: the package layouts (macOS `.app`, Linux tree,
  Windows tree) and a zip and tar.gz writer in plain Ruby, which the hosted task
  uses and the bundled packers are meant to move onto.
- `.github/workflows/hosted-app.yml` packages a hosted app on macOS and Linux
  with that command, opens it against a Rails server, and asserts from the
  servers' side that the app origin reaches the bridge while another origin in
  the same window, a frame of another origin and an unlisted link do not.

- Prebuilt downloads. `bin/rails desktop:runtime` now downloads the relocatable
  interpreter for this machine from the GitHub release matching the gem version
  (gem `0.3.0.pre1`, tag `v0.3.0.pre1`), verifies it against the release's
  `SHA256SUMS`, unpacks it and runs the relocation check — no C toolchain, no
  forty-minute compile. It builds from source only when asked
  (`DESKTOP_RAILS_RUNTIME_FROM_SOURCE=1`) or when the release has nothing for the
  platform, and says which. A bad checksum or a network failure stops instead.
- `bin/rails desktop:shell` does the same for the shell binary, or runs
  `cargo build` in a checkout with `DESKTOP_RAILS_SHELL_FROM_SOURCE=1`.
  `desktop:package` runs it first, so a package has a window by default. The
  downloaded shell is found after `DESKTOP_RAILS_SHELL`, `config.shell_binary`
  and a checkout build.
- `config.release_url` / `DESKTOP_RAILS_RELEASE_URL` and
  `config.release_version` / `DESKTOP_RAILS_RELEASE_VERSION` choose where and
  which release to download from.
- `.github/workflows/release-prebuilt.yml` publishes those downloads for
  arm64-darwin, x86_64-darwin, x86_64-linux and x64-mingw-ucrt on every `v*`
  tag, as a prerelease when the version is one, named by the same code the gem
  uses to find them, then downloads them back on each platform to prove it.
- Rails-native packaging workflow: `rake desktop:runtime`, `desktop:package` and
  `desktop:run`. They shell out to the packaging scripts rather than
  reimplementing them, and fail with a message naming the missing prerequisite.
- The install generator writes `config/environments/desktop.rb` (eager loading,
  loopback-only `config.hosts`, the `:async` job adapter so a forking supervisor
  cannot orphan a server, and writable state under the OS data directory) and an
  executable `bin/desktop-boot`. `--no-desktop-env` skips both.
- `DesktopRails.data_dir`: the per-platform directory a packaged app may write
  to — Application Support, %LOCALAPPDATA% or $XDG_DATA_HOME — honouring the
  `DESKTOP_DATA_DIR` the launchers export. With `DesktopRails.secret_key_base`,
  generated on first run and kept at mode 0600.

- The install generator writes the `desktop:` sections of `database.yml`
  (SQLite in the data directory, mirroring a Rails 8 multi-database layout),
  `cable.yml` and `storage.yml`, ignores `.desktop-rails/`, and pins json below 3
  only while Active Support cannot decode with the installed json.
- `DesktopRails::Database.prepare!`, called by the boot scripts before Puma
  binds: `db:prepare` for every database of the environment, under a lock.
- `DesktopRails::Streams` and `desktop_stream_from`: Turbo Streams over
  server-sent events, served by the engine at `/desktop-rails/stream`.
- `examples/notes`, and `.github/workflows/fresh-app.yml`, which packages a
  freshly generated app with the downloaded runtime and shell and launches it.

### Fixed

- The boot scripts let Puma read the app's `config/puma.rb`, which describes
  the app's deployment, not a desktop server. An app generated by Rails 7.0 or
  7.1 sets a pidfile under `tmp/pids` there, so it died at boot inside its
  read-only bundle with `Errno::ENOENT`. Both boot scripts now skip the file.
- `desktop-rails new` added `gem "desktop-rails", "~> 0.1"`, and the shell
  project it scaffolds depended on `desktop-rails` from npm; neither resolves,
  since nothing is published. Both now come from GitHub at the release tag of
  the CLI's version.
- A missing-packaging-scripts error told people to clone the repository, then
  looked only for a checkout named `desktop_rails` beside the app. A clone named
  `desktop-rails` is found too.
- A packaged app on a fresh machine opened onto an empty database: nothing
  loaded the schema.
- bootsnap wrote its cache inside the bundle on first launch, breaking a signed
  app's seal. The boot scripts point it at the data directory.
- `pack-linux.sh` and `pack-windows.ps1` never vendored path gems or wrote
  `BUNDLE_WITHOUT`, so any app using this gem by path failed to boot there.
- Every packer copied `.desktop-rails/`, `storage/` and `config/master.key` into
  the app it packaged.
- Gems and asset precompilation ran `bin/bundle` and `bin/rails` as executables,
  which Windows cannot do.
- The shell asked port 0 for the path configuration of every bundled app,
  instead of the address the server announced.
- `desktop:package` passed the shell only on macOS. Linux and Windows packages
  now embed it too, as `pack-linux.sh --shell` and `pack-windows.ps1 -Shell`
  already supported.
- A packaged bundle booted `production` even when the app had a desktop
  environment, so none of the settings above reached the app that ships.
  `packaging/templates/boot.rb` now selects it, and `DESKTOP_RAILS_ENV` overrides.

## 0.2.1 (2026-07-29)

Version aligned with the desktop shell's 0.2.1 release, which fixes bridge
events (shell/sudo output streaming, drag & drop, component onReceive) never
reaching pages loaded from the app server. No gem-side API changes.

## 0.2.0 (2026-07-29)

Version aligned with the desktop shell's 0.2.0 release (server auto-start,
Windows support, cross-platform sudo, drag & drop, file associations,
clipboard, launch-at-login). No gem-side API changes.

## 0.1.1 (2026-07-27)

### Added

- Install generator: `rails generate desktop_rails:install` scaffolds the initializer.
- Dev Inspector support:
  - `config.inspector_enabled` and the `desktop_rails_inspector_meta_tag` view helper to enable
    the in-app inspector overlay (dev only).
  - The gem now serves the inspector's JavaScript **same-origin** at `/desktop-rails/inspector.js`
    (and its sub-modules), so the desktop shell can `import()` it without extra setup.
  - `config.inspector_mount_path` to match a custom engine mount point.

### Changed

- The default app id is `dev.desktop-rails.<app>` instead of
  `dev.turbodesktop.<app>`. The app id names the data directory, so an app
  that relied on the default and already has users should set `config.app_id`
  to its old value.

- Minimum Ruby version is now 3.3.

## 0.0.1 (2026-03-22)

- Initial release
- User-Agent detection for Desktop Rails apps (`desktop_rails_app?`)
- Platform and architecture detection (`desktop_rails_platform`, `desktop_rails_arch`)
- View helpers for conditional rendering (`desktop_rails_only`, `turbo_web_only`)
- Bridge component data attribute helper (`desktop_rails_bridge`)
- Path configuration endpoint (`/desktop-rails/path-configuration.json`)
- Configurable path configuration rules and User-Agent pattern

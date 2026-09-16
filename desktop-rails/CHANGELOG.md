# Changelog

## Unreleased

### Changed

- Renamed from Turbo Desktop to desktop-rails. The gem is `desktop-rails`, the
  module is `DesktopRails`, the generator is `desktop_rails:install`, the CLI is
  `desktop-rails`, and environment variables start with `DESKTOP_RAILS_`. This
  fork of aguspe/turbo_desktop continues as its own project; the MIT notices of
  the original author are kept.

### Added

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

### Fixed

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

- Minimum Ruby version is now 3.3.

## 0.0.1 (2026-03-22)

- Initial release
- User-Agent detection for Desktop Rails apps (`desktop_rails_app?`)
- Platform and architecture detection (`desktop_rails_platform`, `desktop_rails_arch`)
- View helpers for conditional rendering (`desktop_rails_only`, `turbo_web_only`)
- Bridge component data attribute helper (`desktop_rails_bridge`)
- Path configuration endpoint (`/desktop-rails/path-configuration.json`)
- Configurable path configuration rules and User-Agent pattern

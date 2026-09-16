# Contributing to desktop-rails

Thanks for your interest in desktop-rails, which ships a Rails app as a desktop
app: your views and Hotwire in a native window, with your Ruby bundled inside.
Contributions of all kinds are welcome: bug reports, docs, tests, and features.

## Ways to help

- **Send a pull request** to
  [DonsWayo/desktop-rails](https://github.com/DonsWayo/desktop-rails/pulls). Issues
  are not enabled on the repository at the moment, so a bug report or a feature
  idea is best sent as a pull request: a failing test, a fix, or a change to the
  docs describing what you expected. The templates in `.github/ISSUE_TEMPLATE/`
  list what a useful report includes.
- **Try it on your app** and report what broke the same way. The README's
  [Status](README.md#status) section says what CI proves today; everything
  else is where help is most useful.
- **Improve docs.** The README is the documentation; `docs/` holds guides that
  go deeper, such as [DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Adding a command

A `#[tauri::command]` needs three things, not one. Register it in
`generate_handler!`, add it to `APP_COMMANDS` in `src-tauri/build.rs`, and grant
the generated `allow-<command>` permission in
`src-tauri/capabilities/main.json`.

Miss either of the last two and the command works from bundled pages but is
refused for anything loaded from your server — with `not allowed. Plugin not
found`, visible only in the webview console. `test/acl.test.js` checks all three
stay in step.

New commands should also call `security::ensure_trusted_caller` before doing
anything, so only your app's own origin can reach them.

## Project layout

| Path | What it is |
|------|-----------|
| `desktop-rails/` | The Rails gem: the install generator, the `desktop:*` packaging tasks, boot-time database preparation, view helpers, path configuration, native calls from Ruby. |
| `packaging/` | The packers, the relocatable Ruby build, signing and update tooling, and smoke checks the gem's tasks and CI run. |
| `src-tauri/` | The Rust/Tauri desktop shell (window management, path-configuration routing, OS APIs). |
| `src/`, `packages/bridge/` | The JS layer (`desktop-rails.js`) that intercepts Turbo visits and bridges to native. |
| `cli/` | The `desktop-rails` CLI, which scaffolds a shell project for hosted mode. Not published to npm. |
| `examples/notes/` | A complete app, packaged and driven in CI. |
| `docs/` | Guides beyond the README. |

## Development setup

```bash
git clone https://github.com/DonsWayo/desktop-rails.git
cd desktop-rails
```

What else you need depends on the piece you are working on:

- **The gem and packaging.** A Ruby 3.2 or newer. Point a Rails app at your
  checkout with `bundle add desktop-rails --path /path/to/desktop-rails/desktop-rails`,
  then follow the README's [quick start](README.md#quick-start). The tasks find
  the packaging scripts in the checkout.
- **The shell.** Rust, `cargo install tauri-cli`, and `npm install`. Set
  `DESKTOP_RAILS_SHELL_FROM_SOURCE=1` to have `bin/rails desktop:package` build it
  with cargo instead of downloading the released one, or run it against a server
  with `cargo tauri dev`, as the README's
  [hosted mode](README.md#wrapping-a-server-you-run-yourself) section describes.

## Running the tests

Please run the suite for whichever piece you touched (CI runs all of them):

```bash
# Rails gem
cd desktop-rails && bundle exec rake test

# JavaScript
npm test

# Rust shell
cd src-tauri && cargo test
```

`.github/workflows/fresh-app.yml` packages a freshly generated Rails app and
opens its window on every push; it is the check that says the quick start still
works.

## Pull requests

- **One concern per PR.** Small, focused PRs are reviewed and merged faster.
- Add or update tests for behaviour changes.
- Make sure the relevant test suite passes locally before opening the PR.
- **Commit messages:** please use [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:`, `chore:`, `test:`, optionally scoped like `fix(inspector):`).
  It keeps history readable and helps changelog generation.

## Reporting security issues

Please **do not** open a public pull request for a security vulnerability.
Contact the maintainer privately through the
[DonsWayo](https://github.com/DonsWayo) GitHub profile so it can be addressed
before disclosure.

## License

By contributing, you agree that your contributions are licensed under the project's
[MIT License](LICENSE).

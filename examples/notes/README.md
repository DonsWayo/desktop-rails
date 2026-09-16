# Notes

A small Rails 8 app packaged as a desktop app with desktop-rails. It was
generated, not assembled:

```sh
rails new notes --skip-docker --skip-kamal --skip-thruster --skip-solid \
  --skip-action-mailer --skip-action-mailbox --skip-action-text --skip-active-storage \
  --skip-action-cable --skip-jbuilder --skip-test --skip-system-test \
  --skip-rubocop --skip-brakeman --skip-bundler-audit --skip-ci --skip-devcontainer
bundle add desktop-rails --path ../../desktop-rails
bin/rails generate desktop_rails:install
bin/rails generate model Note title:string body:text
```

What it shows:

- **Turbo Streams over server-sent events.** A new note is broadcast with
  `DesktopRails::Streams` (see `Note`) and every window subscribed with
  `desktop_stream_from "notes"` shows it. No Action Cable.
- **JavaScript to the shell.** `native_controller.js` asks the shell for the
  window's state through `window.DesktopRails` and reports the answer to the
  server, which replies over the stream.
- **Ruby to the shell.** `GET /native/window` asks the shell the same question
  with `DesktopRails::Native.call`, over the control channel. Saving a note
  raises a native notification the same way.
- **A database that arrives with the app.** On first launch the packaged app
  creates its SQLite database in the data directory, loads `db/schema.rb` and
  runs `db/seeds.rb`; after an update it runs pending migrations.

Both native directions write what they got to `native-reports/` in the data
directory, which is how CI asserts them from outside the running window (see
`.github/workflows/fresh-app.yml`).

```sh
bin/rails desktop:run       # boot it the way the packaged app does
bin/rails desktop:package   # build it for this platform
```

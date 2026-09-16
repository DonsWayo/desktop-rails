# desktop-rails

Server-side Rails integration for [Desktop Rails](https://github.com/DonsWayo/desktop-rails) — the Turbo Native pattern for desktop apps.

This gem gives your Rails app awareness of the Desktop Rails shell, exactly like `turbo-rails` does for Turbo Native mobile apps.

## Installation

Add to your Gemfile:

```ruby
gem "desktop-rails"
```

Then run:

```bash
bundle install
rails generate desktop_rails:install
```

## Usage

### Detection

The gem detects Desktop Rails requests via the User-Agent header (`Desktop Rails/0.0.1 (macOS; aarch64)`).

```ruby
# In controllers
if desktop_rails_app?
  # Desktop-specific logic
end

desktop_rails_platform  # => "macos", "windows", "linux", or nil
desktop_rails_arch      # => "aarch64", "x86_64", or nil
```

### View Helpers

```erb
<%# Render only inside the desktop app %>
<% desktop_rails_only do %>
  <button data-controller="sidebar">Toggle Sidebar</button>
<% end %>

<%# Render only for regular web browsers %>
<% turbo_web_only do %>
  <nav class="web-navbar">...</nav>
<% end %>

<%# Bridge component data attributes %>
<%= tag.button "Export PDF",
    **desktop_rails_bridge("menu-item",
      title: "Export PDF",
      shortcut: "Cmd+E"
    ) %>
```

### Desktop-only templates

Requests from the desktop app are marked with a Rails variant, so a whole
template can be written for it rather than branching inside a shared one:

```
app/views/orders/show.html.erb           # everyone
app/views/orders/show.html+desktop.erb   # the desktop app
```

Layouts work the same way — `app/views/layouts/application.html+desktop.erb`.
Rails falls back to the plain template wherever no variant exists, so this costs
nothing until you add one.

The block helpers above are still the right tool for a button or a nav bar. Reach
for a variant when the whole page differs.

Rename it, or turn it off, in the initializer:

```ruby
DesktopRails.configure do |config|
  config.variant = :desktop   # nil leaves variants alone
end
```

It is added to any variants you have already set rather than replacing them.

### Path Configuration

The gem mounts a path configuration endpoint at `/desktop-rails/path-configuration.json`:

```ruby
# config/initializers/desktop_rails.rb
DesktopRails.configure do |config|
  config.path_configuration = {
    settings: { screenshots_enabled: true },
    rules: [
      { patterns: ["/"], properties: { presentation: "default" } },
      { patterns: ["/new$", "/edit$"], properties: { presentation: "modal" } },
      { patterns: ["/settings"], properties: { presentation: "native" } }
    ]
  }
end
```

## Packaging, from Rails

Building a desktop app should not mean running a shell script with five flags.
The generator sets up the desktop environment, and three rake tasks do the rest.

```bash
bin/rails generate desktop_rails:install   # initializer, desktop env, bin/desktop-boot
bin/rails desktop:runtime                  # fetch or build a relocatable Ruby, once
bin/rails desktop:run                      # boot the app the way a bundle will
bin/rails desktop:package                  # a .app, a Linux tree, or a Windows zip
```

The tasks shell out to the packaging scripts in the desktop_rails repository
rather than reimplementing them, and each one fails with a message naming what is
missing and how to supply it. Point them at a checkout with
`DESKTOP_RAILS_PACKAGING`, or in the initializer with `config.packaging_dir`.

### The desktop environment

`config/environments/desktop.rb` is not production and not development. A desktop
app is a single-user server on loopback inside a read-only, code-signed bundle,
and each setting follows from one of those facts:

- **`eager_load`, no reloading.** The bundle cannot be edited while it runs, and
  eager loading moves an autoload error to boot instead of to a page the user has
  already opened.
- **`config.hosts` is loopback and nothing else.** The webview asks for the exact
  origin the server announced. Clearing `config.hosts` instead would also accept a
  request carrying someone else's `Host` header.
- **`:async` jobs.** A forking job supervisor is the most effective way there is
  to orphan a server: the shell closes the child's stdin, the child exits on EOF,
  and the workers it forked keep the port and never notice. In-process jobs share
  the fate of the process that owns the window. The cost is real — jobs die with
  the app and are not retried — so durable background work needs a database-backed
  queue with its own lifecycle, not a forking supervisor inside the bundle.
- **Everything writable lives in `DesktopRails.data_dir`**, including a
  `secret_key_base` generated on first run at mode 0600, because a bundle a
  stranger downloads has no credentials key and no operator to give it one.

`bin/desktop-boot` is the script both `desktop:run` and the packaged app execute,
so a failure in one is a failure in the other.

### Where a desktop app may write

Rails has no concept of an OS data directory, because a server owns its
deployment directory. A desktop app does not.

```ruby
DesktopRails.data_dir             # => Pathname
DesktopRails.data_dir(create: true).join("ledger.sqlite3")
```

| Platform | Directory |
| --- | --- |
| macOS | `~/Library/Application Support/<app id>` |
| Windows | `%LOCALAPPDATA%\<app id>` |
| Linux | `$XDG_DATA_HOME/<app id>`, or `~/.local/share/<app id>` |

`DESKTOP_DATA_DIR` overrides all three. The launchers the packers write export it
after making the same decision in shell, so the shell and the Rails app can never
disagree about where state lives.

The app id defaults to `dev.turbodesktop.<your-app-name>`; set
`config.app_id` and `config.app_name` in the initializer to choose your own.

## Requirements

- Ruby >= 3.3
- Rails >= 7.0
- turbo-rails >= 1.0

## License

MIT — see [LICENSE](LICENSE) for details.

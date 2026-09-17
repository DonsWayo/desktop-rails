<p align="center">
  <img src="desktop-rails-icon.png" alt="desktop-rails" width="180" />
</p>

<h1 align="center">desktop-rails</h1>

<p align="center">
  <strong>Ship your Rails app as a desktop app</strong> — your views and Hotwire in a native window, your Ruby bundled inside, for macOS, Linux and Windows
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> •
  <a href="#two-ways-to-use-it">Two ways to use it</a> •
  <a href="#status">Status</a> •
  <a href="#bridge-components">Native features</a> •
  <a href="#rails-gem">Rails gem</a> •
  <a href="examples/notes">Example app</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Tauri-2-blue?logo=tauri" alt="Tauri 2" />
  <img src="https://img.shields.io/badge/Rails-7.0_to_8.1-red?logo=rubyonrails" alt="Rails 7.0 to 8.1" />
  <img src="https://img.shields.io/badge/Hotwire-Turbo_Streams_over_SSE-yellow" alt="Hotwire" />
  <img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License" />
</p>

---

Rails developers have Hotwire Native for phones and nothing for the desktop.
desktop-rails packages a Rails app into a native application: a small
[Tauri 2](https://tauri.app) window using the operating system's webview, a
relocatable Ruby, your app and its gems, and a SQLite database created in the
user's data directory on first launch. Nobody installs Ruby. Your views,
Turbo Frames, Turbo Streams and Stimulus controllers work as they do on the web,
and both JavaScript and Ruby can call native features such as notifications,
the clipboard, window control and scoped file access.

desktop-rails continues [aguspe/turbo_desktop](https://github.com/aguspe/turbo_desktop)
as its own project.

## Quick start

You need a Rails app, 7.0 or newer, and a Ruby (3.2 or newer) to run its
generators. No Rust or Node is needed. Your gems are installed for the bundled
Ruby, so gems with native extensions need the same build tools they always do.

```bash
bundle add desktop-rails --github DonsWayo/desktop-rails
bin/rails generate desktop_rails:install
bundle install               # only if the generator says it changed the Gemfile
bin/rails desktop:runtime    # downloads the Ruby your app will ship with
bin/rails desktop:package    # downloads the window app and builds the bundle
```

The bundle lands in `.desktop-rails/dist/`: a `.app` on macOS, a directory tree
on Linux, and a directory with a launcher plus a zip of it on Windows. To boot
the app the way the bundle does, without a window:

```bash
bin/rails desktop:run
```

The generator adds a `desktop` Rails environment, the database, cable and
storage settings for it, and `bin/desktop-boot`, which is what the packaged app
runs. On every launch the app brings its databases up to date before it accepts
a request: a new install loads `db/schema.rb` and seeds, and an update runs
pending migrations.

This exact sequence runs on every push: a freshly generated Rails app is
packaged on macOS, Linux and Windows, and its window is opened on macOS and
Linux ([fresh-app.yml](.github/workflows/fresh-app.yml)). On macOS and Linux
that is done once for each of Rails 7.0, 7.1, 7.2 and 8.1, at their latest
patch releases; on Windows with 8.1.

[examples/notes](examples/notes) is a complete app built this way. It streams
Turbo updates over server-sent events without Action Cable, and calls the shell
from both a Stimulus controller and a Rails controller.

## Two ways to use it

**Bundled.** The quick start above. The app ships with its own Ruby and runs
entirely on the user's machine, which suits tools that work offline and keep
their data locally.

**Hosted.** The window opens a Rails app you already run on a server, the way
Hotwire Native apps do on phones. Nothing is bundled but the window app, and
the same native features are available to pages from that server's origin. See
[Wrapping a server you run yourself](#wrapping-a-server-you-run-yourself).

The shell also works without Ruby. Any server-rendered Hotwire app can sit
behind it in hosted mode.

## Status

desktop-rails is a prerelease. It is installed from GitHub rather than
RubyGems until it has been proven with more apps than its own examples.

| Platform | Package | Window opened in CI | Native calls tested in CI |
|---|---|---|---|
| macOS (Apple Silicon, Intel) | `.app` | yes | JavaScript and Ruby |
| Linux x86_64 (glibc) | directory tree | yes | JavaScript and Ruby |
| Windows x64 | directory and zip | no | no |

Known limits:

- **macOS signing.** Bundles are signed ad hoc. Gatekeeper blocks them on other
  people's Macs until they are signed with a Developer ID and notarized; see
  [packaging/DISTRIBUTION.md](packaging/DISTRIBUTION.md).
- **Linux.** The window needs WebKitGTK 4.1 on the user's machine. ARM and musl
  Linux have no prebuilt downloads, so `desktop:runtime` compiles Ruby from
  source there and packages have no window.
- **Hosted mode** is packaged and opened in CI on macOS and Linux, with the
  bridge's origin checks driven from inside the window
  ([hosted-app.yml](.github/workflows/hosted-app.yml)). Its Windows package is
  built only in the test suite. Its secure defaults are in the shell, so use
  0.3.0.pre3 or later.

## How it fits together

```
┌────────────────────────┐  stdin: control URL + token   ┌──────────────────────┐
│ Tauri shell (Rust)     │ ────────────────────────────▶ │ Ruby + your Rails app│
│ window, menus, tray,   │ ◀──────────────────────────── │ Puma on 127.0.0.1:0  │
│ native features        │  stdout: {"url": ...}         │ bin/desktop-boot     │
└──────────┬─────────────┘                               └──────────┬───────────┘
           │ webview loads the announced URL                        │
           ▼                                                        │
┌────────────────────────┐   HTML, Turbo Streams over SSE           │
│ Your views + Hotwire   │ ◀────────────────────────────────────────┘
│ window.DesktopRails    │   Ruby calls native features through the
└────────────────────────┘   token-protected control channel
```

The server listens on a random loopback port and announces it on its first line
of output. The shell hands it a control-channel URL and token over stdin, which
is also how the server knows to exit: when the shell goes away, even by force
quit, stdin closes and the server stops. The bundle is read-only; everything the
app writes goes to the operating system's data directory.

## Wrapping a server you run yourself

Hosted mode: the window opens a Rails app you already run on a server, the way a
Hotwire Native app wraps your site on a phone. The package is the prebuilt shell
and one config file. Building it needs neither Rust nor a relocatable Ruby, and
nothing but the shell runs on the user's machine.

This path is run on every push against a real Rails server on macOS and Linux
([hosted-app.yml](.github/workflows/hosted-app.yml)): the package is built with
the command below, the window loads the server's page, the page reaches the
bridge, and a second origin in the same window is refused.

### 1. Add the gem

```bash
bundle add desktop-rails --github DonsWayo/desktop-rails
```

Your server does not need the `desktop_rails:install` generator; that sets up
the desktop environment a bundled app runs in.

### 2. Write the config

`config/desktop-rails.config.json`:

```json
{
  "server_url": "https://app.example.com",
  "app_name": "Acme Assistant",
  "window": { "width": 1100, "height": 800 }
}
```

That is a complete, closed config: the window opens `server_url`, pages from that
origin can use the notification, window, badge, global shortcut, menu item,
clipboard-write and file-picker components, and nothing that reaches the machine
beyond a file the user picks is open. Widen it only where the app needs to — see
[Capabilities](#capabilities-and-what-a-compromised-page-can-do).

> `path_configuration_url` is optional — it defaults to
> `{server_url}/desktop-rails/path-configuration.json`.

### 3. Package it

```bash
bin/rails desktop:package:hosted
```

It downloads the shell for this platform (`desktop:shell`), checks the config,
prints what a page from `server_url` will be able to reach, and writes to
`.desktop-rails/dist/`:

| Platform | Result |
|---|---|
| macOS | `Acme Assistant.app`, signed ad hoc (or with `config.signing_identity`) |
| Linux | `acme-assistant/` (the shell, its config, a `.desktop` entry) and `acme-assistant-linux-x86_64.tar.gz` |
| Windows | `acme-assistant/` (`acme-assistant.exe` and its config) and `acme-assistant-windows-x64.zip` |

| Variable | Meaning |
|---|---|
| `DESKTOP_RAILS_CONFIG` | The config file, if not `config/desktop-rails.config.json` |
| `DESKTOP_RAILS_SERVER_URL` | Replaces `server_url`, so one config builds staging and production |
| `DESKTOP_RAILS_APP_ID` | Bundle identifier; also names the data directory |
| `DESKTOP_RAILS_ICON` | A `.png` (or `.icns` on macOS). A Windows executable keeps the shell's icon |
| `DESKTOP_RAILS_SHELL` | A shell binary to use instead of downloading one |

The config is refused, before anything is built, when `server_url` is plain
`http` anywhere but this machine, when it has a `server.command` (a hosted app
starts nothing on the user's machine), when an `updater` block is half filled,
or when it has a key the shell does not read, since the shell silently ignores
a misspelt `"shel"`.

> The secure defaults below are in the shell. Shells from 0.3.0.pre3 on carry
> them; the 0.3.0.pre1 and pre2 shells do not.

### Capabilities, and what a compromised page can do

Treat every page in the window as code you do not fully control. A hosted app
shows a production website, and an XSS on it, a compromised script from a CDN,
or a page the window was talked into loading all run with whatever the bridge
allows. The config is therefore closed by default and opened per capability:

| Capability | With no config | To open it |
|---|---|---|
| Which pages may call the bridge | Only `server_url`'s origin: same scheme, host and port | Nothing widens this |
| `shell` (run processes) | Refused | `"shell": { "enabled": true, "allowed_commands": ["git status"], "allowed_env": [] }` |
| `sudo` (run as administrator) | Refused | `"sudo": { "enabled": true, "allowed_commands": [...] }` |
| `filesystem` | Only files and folders the user picked in a dialog or dropped on a window, for the session | `"filesystem": { "allowed_roots": ["~/Projects", "$APP_DATA"] }` |
| `clipboard` | Write only | `"clipboard": { "read": true }` |
| Other sites | Open in the browser | `"navigation": { "internal_hosts": ["accounts.google.com"] }` loads them in the window, still without the bridge |
| `updater` | Off | `endpoints` and `pubkey` together; only signed updates install |
| `notification` | Available to `server_url` and the app's Ruby | `"notifications": { "enabled": false }` turns it off |
| `shortcut` (global shortcuts) | Available to `server_url` and Ruby: combinations with a Control, Alt/Option or Command/Super modifier, at most 20 | `"shortcuts": { "enabled": false }` turns it off; `"summon": "CmdOrCtrl+Shift+Space"` adds a window-summoning shortcut with no page code |
| `badge`, `window`, `menu-item`, `file-picker`, `autostart` | Available to `server_url` | — |

What stops a page that is *not* the app:

- **Other origins.** Tauri checks the origin of the frame that sent each call
  against `server_url`'s exact origin before any command runs, and the command
  checks the page the window shows as well. A different host, a lookalike
  (`app.example.com.evil.com`, `app.example.com@evil.com`), another port, or an
  `http://` downgrade of an `https://` app is refused.
- **Links and redirects.** A link to another site opens in the system browser
  and the window stays on the app. A host in `internal_hosts` loads in the
  window, and is still refused by the bridge.
- **Frames.** An `<iframe>` of another origin gets neither Tauri's invoke
  function nor the key it needs, and the ACL judges the frame, not the page
  around it.

What it does not stop: a script running *on* `server_url`'s origin is the app as
far as the shell can tell. Whatever the config opens, an XSS on your site can
use. Open `shell`, `sudo` and filesystem roots only if the app cannot work
without them, name the narrowest commands and roots it needs, and keep your
site's Content Security Policy tight.

### 4. Serve path configuration from Rails

```ruby
# config/routes.rb
get "/desktop-rails/path-configuration", to: "desktop_rails#path_configuration"
```

### 5. Develop against it

To try a config against a local server before packaging, point `server_url` at
`http://localhost:3000` (plain http is allowed on loopback) and package as above,
or run a shell you built from source with the config in the working directory.

#### Building the shell from source

For working on the shell itself. Needs Rust (and the WebKitGTK development
packages on Linux):

```bash
git clone https://github.com/DonsWayo/desktop-rails.git
cd desktop-rails/src-tauri
cargo build --release   # target/release/desktop-rails
```

`bin/rails desktop:shell` uses a build in a checkout automatically when the gem
comes from that checkout, and `DESKTOP_RAILS_SHELL` points at one anywhere else.
A debug build (`cargo build`, or `cargo tauri dev` with `tauri-cli`) reads
`desktop-rails.config.json` from the directory it runs in.

### The config in detail

#### Where the rules come from

The server is the source of truth, but it is not always reachable, so the shell
starts with rules rather than none — the same layering Hotwire Native uses:

1. **The last copy the server gave**, cached in the user's config directory.
2. **The copy bundled with the app** (`path-configuration.json` beside your app
   config), for a first run before the server has ever answered.
3. Failing both, everything routes to the default presentation.

The server's copy replaces whichever was loaded as soon as it arrives, and is
cached for next time. A cold start with your server down therefore keeps the
routing you had, instead of silently sending every route to the default and
making modals appear to stop working.

Keys the desktop shell does not use — Hotwire Native's `settings`, say — are
ignored, so one endpoint can serve every shell.

`server_url` is also the app's trust boundary: the bridge only answers calls from
pages on that exact origin (scheme, host and port). A page from anywhere else —
an off-site link, a redirect, an embedded frame — gets a refusal instead of
native access. See [Bridge security](#bridge-security).

The window is created from this file at startup, so `app_name`, `user_agent` and
the `window` block all take effect. `user_agent` **replaces** the webview's own
string rather than extending it, so keep the `Desktop Rails` token — the Rails
gem's `desktop_rails_app?` and the `desktop_rails_only` helper match on it.

#### Where the config is read from

This file carries the app's trust boundary, so where it is read from matters:

- **In development**, it is read from the project you run in — the working
  directory or one level up, so both `desktop-rails dev` and `cargo tauri dev`
  find it. If there is none, the app starts on defaults.
- **In a packaged app**, it is read only from inside the bundle
  (`Contents/Resources` on macOS), never from the working directory, and the app
  **refuses to start** if it is missing. It ships there via `bundle.resources` in
  `tauri.conf.json`, and `desktop-rails build` includes it automatically.

A config that exists but does not parse is always fatal, in both cases.

#### User preferences

The window size the user leaves the app at is remembered separately, in their own
config directory (`~/Library/Application Support/<bundle id>/preferences.json` on
macOS), and reapplied on the next launch:

```json
{ "window": { "width": 1440, "height": 900 } }
```

That file is the only user-writable input the app reads, and it can hold nothing
but geometry. Adding a `sudo` or `server_url` key to it has no effect — the type
it deserializes into has nowhere to put them. Sizes that would produce an
unusable window (below the configured minimum, negative, not a number) fall back
to the configured defaults, and a corrupt file is ignored rather than fatal,
since losing a remembered window size should not stop the app from starting.

Only size is remembered, not position: a remembered position becomes an
off-screen window as soon as the display arrangement changes.

The reason for the split is that a writable config is a way around every other
protection here: `server_url` decides which origin the bridge trusts, and the
filesystem roots and sudo allowlist sit in the same file. Reading it from the
working directory of a shipped app would let anyone who can write a file next to
it grant themselves shell and sudo access. Note that the bundle only becomes
tamper-*resistant* once you sign the app — see
[Signing & notarization](#distribution).

If the server is not reachable when the app launches, it opens a bundled page
that waits and redirects once your server answers.

#### Starting the server automatically

With a `server` block, opening the app starts your Rails server too, so the app
behaves like an application rather than a viewer for something you have to run
first:

```json
{
  "server": {
    "command": "bin/rails server",
    "directory": ".."
  }
}
```

- `command` runs through your login shell on macOS and Linux, so a Ruby version
  manager (rbenv, asdf, mise) is set up the same way it would be in a terminal.
  On Windows it runs through `cmd`, and the Unix `bin/rails` binstub does not
  apply — set `command` to `ruby bin\rails server` there.
- `directory` is resolved relative to the config file and defaults to `..` —
  the project root, one level above `desktop/`.

If something is already listening on `server_url` — a server you started by
hand, say — the app leaves it alone: it neither starts a second one nor kills
yours on quit. A server the app did start is stopped when the app quits.

Omit `command` (or the whole block) to manage the server yourself. A hosted
package refuses a `command`: it would run on every machine the app is installed
on.

#### Updating a shipped app

With an `updater` block, the app can check a URL for a newer version and replace
itself. The endpoint and the signing key live here rather than in
`tauri.conf.json` because that file is compiled into the shell, and one shell
binary serves every app built with this fork:

```json
{
  "updater": {
    "endpoints": ["https://downloads.example.com/ledger/latest.json"],
    "pubkey": "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6...",
    "current_version": "1.1.0"
  }
}
```

- `pubkey` is the minisign public key `desktop-rails-tool updater generate-key` prints.
  Downloads that are not signed by its private half are refused, so the key is
  what makes an update server safe to trust.
- `endpoints` must be https. The plugin allows plain http in development and
  refuses it in a release build, so an http endpoint works until you ship.
- `current_version` is the version this installation actually is. Without it the
  comparison uses the shell's own version, which belongs to the framework rather
  than to your app.

Omit the block, or either required field, and the app does not check for updates
at all — `DesktopRails.updater.check()` answers `{ status: "not_configured" }`.

Making the key and signing a release: [packaging/AUTO_UPDATE.md](packaging/AUTO_UPDATE.md).
## Path Configuration

The path configuration is a JSON file that maps URL patterns to presentation rules — the same concept from turbo-ios and turbo-android.

```json
{
  "settings": {
    "screenshots_enabled": true,
    "pull_to_refresh_enabled": false
  },
  "rules": [
    {
      "patterns": ["/"],
      "properties": { "presentation": "default" }
    },
    {
      "patterns": ["/new$", "/edit$"],
      "properties": { "presentation": "modal", "title": "Edit", "width": 640, "height": 480 }
    },
    {
      "patterns": ["/reports/"],
      "properties": { "presentation": "new_window" }
    },
    {
      "patterns": ["/settings"],
      "properties": { "presentation": "native" }
    }
  ]
}
```

| Presentation | Behavior |
|---|---|
| `default` | Navigate in the current window (Turbo Drive handles it) |
| `modal` | Open the URL in a modal-style window (800×600 unless the rule sets `width`/`height`) |
| `new_window` | Open the URL in a full separate window (1200×800) |
| `replace` | Replace the current page with no back-navigation |
| `native` | Emit a `native-screen-requested` event for Rust UI |
| `none` | Do nothing — handled entirely by a Bridge Component |

## Bridge Components

The Bridge is the desktop equivalent of **Strada**. It lets your web components talk to native OS features through structured message passing.

### Built-in Components

| Component | Description |
|---|---|
| `notification` | OS notifications; a click brings the window forward — see [Notifications](#notifications) |
| `menu-item` | Items in the app's menu bar that trigger page actions — see [Menu items](#menu-items) |
| `file-picker` | Open native file-open/save dialogs |
| `badge` | The Dock or launcher badge count — see [Badge](#badge) |
| `shortcut` | Global keyboard shortcuts, and a config-only one that summons the window — see [Global shortcuts](#global-shortcuts) |

What each platform does, and what CI proves of it
(`.github/workflows/native-features.yml`):

| | macOS | Linux | Windows |
|---|---|---|---|
| Notification | `NSUserNotificationCenter`, sent under the app's bundle id. No click event | `org.freedesktop.Notifications` on the session bus; a click is reported | A toast; a click is reported |
| Badge | Dock count, or a short label | Count through the Unity `LauncherEntry` signal (Ubuntu dock, Dash to Dock, Plasma, Plank); no labels | None: resolves with `supported: false` |
| Global shortcut | Yes | X11, and XWayland under Wayland, where it only fires while an X11 window has focus (the reply carries a `warning`) | Yes |
| Menu item | App menu bar | Window menu bar | Window menu bar |
| CI asserts | Each call's answer, Ruby's notification accepted by the OS; key presses and the Notification Center are reported only where the runner allows | The notification service received each `Notify`, the badge signal went out, keys pressed with `xdotool` fire the page's shortcut and summon the window, a taken combination is refused, a menu accelerator and a notification click reach the page | Not run |

### Notifications

```js
await DesktopRails.notifications.show({ title: "Export finished", body: "invoice.pdf", id: "export-42" })
DesktopRails.notifications.onClick(({ id }) => Turbo.visit(`/exports/${id.split("-")[1]}`))
```

`show()` resolves with `{ status: "shown", id, clickable }` once the platform's
notification service has taken the notification, and rejects with the reason
when it cannot: no notification service (a Linux session without a daemon), a
macOS process that is not running from its `.app`, or the config turning
notifications off. A notification with the same `id` as an earlier one replaces
it where the platform can (Linux).

Clicking a notification shows and focuses the main window and dispatches
`desktop-rails:notification-click` with `{ id }` on every open page (and calls
`onClick`). macOS activates the app on a click itself and reports nothing back,
so `clickable` is `false` there.

Permission: desktop platforms do not prompt. `notifications.permission()` (and
`requestPermission()`, which is the same) is `"granted"` when a Linux
notification service answers, `"unavailable"` when there is none, `"denied"`
when the config turned notifications off, and `"unknown"` on macOS and Windows,
which cannot say without a prompt or a signed bundle. The person using the app
can still silence it in the system settings.

From Ruby, with no page open:

```ruby
DesktopRails::Native.notify(title: "Export finished", body: "invoice.pdf", id: "export-42")
DesktopRails::Native.notification_permission # => "granted"
```

`notify` returns the shell's reply and raises `DesktopRails::Native::CallFailed`
when the notification could not be shown. Outside the shell it is `nil`.

Notifications are on for `server_url` by default; `"notifications": { "enabled": false }` turns them off.

### Badge

```js
await DesktopRails.badge.set(3)          // { supported: true, count: 3 } on macOS and Linux
await DesktopRails.badge.setLabel("new") // macOS only; elsewhere { supported: false }
await DesktopRails.badge.clear()
```

A count of 0 clears. Windows has no badge for a desktop app, so the call is a
no-op that says `supported: false` rather than an error. Ruby:
`DesktopRails::Native.badge(3)`, `.badge_label("new")`, `.clear_badge`.

### Global shortcuts

Combinations that reach the app while another application has focus: the
"summon the assistant from anywhere" key.

```js
await DesktopRails.shortcuts.register("palette", "CmdOrCtrl+Shift+K", { focus: true })
DesktopRails.shortcuts.on("palette", () => this.openPalette())
// or: data-action="desktop-rails:shortcut@document->palette#open"  (detail: { id, accelerator })
await DesktopRails.shortcuts.unregister("palette")
```

The contract:

- **Ids.** Each shortcut has an id of your choosing (letters, digits, `-_.:`),
  which is what the event carries. `focus: true` shows and focuses the main
  window before the page hears about it.
- **Reloads.** Shortcuts belong to the app, not the page, and survive
  navigation. Registering the same id and combination again resolves with
  `alreadyRegistered: true` and grabs nothing twice, so a controller can simply
  register in `connect()`. The same id with a new combination replaces the old
  one (`replaced: true`). Every open page hears a shortcut fire.
- **Conflicts reject.** A combination another id holds, the config's summon
  combination, or a combination another application or the OS already grabbed
  rejects with the reason ("another application or the system already uses
  it"), rather than resolving as if it worked. The OS cannot always tell: macOS
  lets two apps register the same hot key, so a clash there is not detectable.
- **Limits.** A combination needs a Control, Alt/Option or Command/Super
  modifier — Shift alone is still typing — and pages hold at most 20 shortcuts,
  so a page cannot capture typing meant for other applications.
- `unregisterAll()` releases everything pages registered; `list()` shows it.

**Summon without page code.** A hosted app can bring its window forward with a
config entry alone. The shell registers it at startup, shows and focuses the
main window when it fires, and dispatches `desktop-rails:summon`:

```json
{ "shortcuts": { "summon": "CmdOrCtrl+Shift+Space" } }
```

`desktop:package:hosted` refuses a summon combination the shell would not
accept. Page registration is on by default; `"shortcuts": { "enabled": false }`
turns it off and leaves `summon` working.

### Menu items

```js
await DesktopRails.menu.add({ id: "export", title: "Export PDF", accelerator: "CmdOrCtrl+Shift+E", menu: "File" })
DesktopRails.menu.onClick("export", () => this.export())
// or: data-action="desktop-rails:menu-item@document->report#export"  (detail: { id })
await DesktopRails.menu.remove("export")
```

`menu` names a top-level menu: an existing one ("File", "View") or a new one,
created before "Window" and removed with its last item. Like shortcuts, items
belong to the app and adding the same item again is `alreadyRegistered`. An
accelerator the app menu already uses (Quit, Reload, Copy, …) or another item
holds is refused. A menu accelerator only fires while the app's window has
focus; use a global shortcut for anything else.

The notification, badge, shortcut and menu APIs reject with the shell's reason
on a refusal. `sendBridgeMessage()` still resolves to `null` on any error, as it
always has; `DesktopRails.invokeBridge()` is the rejecting form for your own
components.

### Modal and secondary windows

A rule with `presentation: "modal"` or `"new_window"` opens the URL in its own
window, sized by the rule's `width` and `height`. These carry everything the
main window does — the user agent your Rails app detects on, off-origin links
going to the browser, and a working bridge.

A page in one of these windows knows where it is and can dismiss itself:

```js
if (DesktopRails.isModal) {
  DesktopRails.closeModal()      // no argument: closes the window it is in
}
DesktopRails.windowLabel         // e.g. "modal-9b8b948"
```

#### Dismissing a modal

Closing a modal usually means something for the screen underneath. The three
outcomes are named after Hotwire Native's, and mean the same things:

```js
DesktopRails.recede()    // close, and go back underneath
DesktopRails.refresh()   // close, and reload underneath — after a form submits
DesktopRails.resume()    // close, and leave underneath alone
```

`refresh()` goes through Turbo when it is present, so scroll position and
morphing are preserved, and falls back to a reload when it is not.

A modal is attached to the main window, so it travels with it and closes with
it rather than being left behind. That is ownership, not modality: the main
window stays interactive. A blocking sheet needs AppKit APIs Tauri does not
expose. Secondary windows (`new_window`) are meant to stand alone and are not
attached.

### Deep links

A link from outside — an email, a calendar entry, another app — can open your
app at a particular page:

```
task-manager://orders/123?ref=email
```

becomes a Turbo visit to `{server_url}/orders/123?ref=email`, so your path
configuration still decides how it is presented.

**The scheme is per app.** `desktop-rails new` derives it from the app name and
writes it into `tauri.conf.json`, along with a matching bundle identifier. It
belongs there rather than in `desktop-rails.config.json` because the operating
system needs it at build time: macOS reads it from the app's `Info.plist`,
Windows from a registry key written at install.

That per-app choice matters. No desktop OS arbitrates duplicate scheme
registrations in a way you control — on Windows the last installer wins, on
macOS Launch Services decides — so if every app built on this shell shared one
scheme, installing two of them would send one app's links to the other. Pick
something distinctive: nothing stops unrelated software registering the same
string.

Links are resolved against `server_url` and refused if they point anywhere else.
A deep link arrives from outside the app, so it is not trusted to say where to
go.

To change the scheme later, edit `plugins.deep-link.desktop.schemes` in
`tauri.conf.json` — and expect links already sent to stop working.

### Refreshing when you come back

Mobile shells reload when the app returns to the foreground, and data goes stale
here for the same reason. A desktop window loses focus far more often though —
every glance at another app — so this is opt-in and waits for an absence long
enough to matter:

```json
{
  "navigation": {
    "refresh_after_seconds": 300
  }
}
```

Coming back sooner than that does nothing. Omit the key, or set it to `0`, and
the shell never refreshes on its own.

A refresh goes through Turbo when it is present, so with `turbo-refresh-method`
set to `morph` the page updates in place rather than being thrown away.

**It will not interrupt someone typing.** If the focus is in a field or a
contenteditable element when the window returns, the refresh is skipped — losing
half a form is worse than showing data a few seconds old.

Every return is announced whether or not a refresh is proposed, so an app can
revalidate its own way, or veto a refresh it knows is unsafe:

```js
document.addEventListener("desktop-rails:focus", (event) => {
  const { awaySeconds, refreshing } = event.detail
  if (refreshing && hasUnsavedChanges()) event.preventDefault()
})
```

### External links

Links to anywhere other than your app open in the system browser, the same way
Hotwire Native treats off-origin links. Without that, following a link to a
payment provider or a terms page replaces your app in its own window and leaves
the person with no way back. `mailto:`, `tel:` and other non-web schemes go to
whichever app owns them.

This is decided in the shell rather than in JavaScript, because Turbo only
intercepts same-origin links — an off-origin one never reaches the web layer at
all. Ordinary navigations, `target="_blank"`, `window.open` and path
configuration rules pointing off-origin all go the same way.

Sometimes you need a third-party page *inside* the app: an OAuth round trip has
to happen in this webview for the session cookie to land in the right place.
List those hosts:

```json
{
  "navigation": {
    "internal_hosts": ["accounts.google.com"]
  }
}
```

Matching is exact, so `example.com` does not admit `evil-example.com` or
`sub.example.com`. Being internal is not the same as being trusted: the bridge
still answers only your app's own origin, so a listed host can render but cannot
reach the shell.

### Connection loss and error pages

The shell watches your server and reports failures using the same vocabulary as
Hotwire Native, so `network_failure`, `timeout_failure`, `http_failure` and
`page_load_failure` mean here what they mean on turbo-ios and turbo-android.

**What happens by default.** If your server is unreachable at launch, the window
opens on a bundled error page. If it goes away while the app is running, a
banner appears. Either way the shell keeps probing, and puts the window back on
your app as soon as the server answers — you do not have to do anything.

The shell is what notices this, not the web layer, because the browser's
`offline` event fires when *this machine* loses its network, not when your
server goes down. The second is the case that actually happens.

**Customising the error page.** `desktop/src/error.html` is yours. It is
bundled with your app, so it must work with no network: inline everything, no
CDN fonts or remote stylesheets. It receives the server URL as
`window.__DESKTOP_RAILS_SERVER_URL__` and the reason as an `?error=` parameter.

**Handling failures in your app instead.** Listen for `desktop-rails:visit-error`
and call `preventDefault()` to suppress the shell's banner for that failure:

```js
document.addEventListener("desktop-rails:visit-error", (event) => {
  const { error, status, retry } = event.detail
  event.preventDefault()
  showMyOwnBanner(error, status, retry)   // retry() attempts the visit again
})
```

`retry` is the desktop counterpart of the retry handler Hotwire Native passes to
a failed visitable. To take over presentation entirely rather than case by case:

```html
<meta name="desktop-rails-error-handling" content="manual">
```

There is also `desktop-rails:connection` with `{ online, error }` for reacting to
the connection dropping and returning without tying it to a specific visit.

Server errors your app can render itself are left alone — a 404 or a 422 is your
page to serve. Only 5xx responses and failures to reach the server at all are
reported.

### Bridge security

The bridge reaches the shell, the filesystem and administrator privileges, so it
is closed by default and opened deliberately. The table of defaults and the
threat model are under
[Capabilities](#capabilities-and-what-a-compromised-page-can-do); this is how
each piece works.

**Origin.** Only pages from `server_url`'s origin (or, in a bundled app, the
address its own server announced) can call the shell's commands. Tauri checks
the origin of the frame that sent each call before the command runs, and every
command checks the page its window is showing as well, so neither an embedded
frame of another origin nor a request that races a navigation gets through.
Remote pages cannot call Tauri plugin commands directly at all.

**Shell.** The `shell` component is off unless you enable it and list the
commands it may run, matched like `sudo` below against the command and its
arguments. Arguments are quoted before they reach the login shell; the command
itself may not contain shell metacharacters. A page may only set environment
variables named in `allowed_env` (`PATH`, `BASH_ENV` or `LD_PRELOAD` would turn
an allowed command into a different program), and a `cwd` must be inside the
filesystem scope.

```json
{
  "shell": {
    "enabled": true,
    "allowed_commands": ["git status", "bin/setup"],
    "allowed_env": ["GIT_DIR"]
  }
}
```

**Filesystem.** The `filesystem` component can only read and write under the
roots you declare, plus what the user grants (below). With no configuration
there are no roots. `$APP_DATA` names the app's own data directory. Paths are
resolved before the check, so `..` and symlinks cannot walk out of a root, and
locations like `.ssh`, `.aws`, `.gnupg` and Rails `master.key` /
`credentials.yml.enc` are refused even inside one.

```json
{
  "filesystem": {
    "allowed_roots": ["~/Projects", "$APP_DATA/exports"]
  }
}
```

A path the user picks in a native file dialog is treated as consent for that
path: picking a file (open or save) makes that one file readable and writable,
picking a folder covers everything inside it. So "Save As… → Desktop" works
without listing `~/Desktop` as a root. Grants last for the session only, and
the protected locations above stay refused even when picked.

**Sudo.** The `sudo` component is off unless you enable it and name the commands
it may run. A command is matched whole or as a prefix up to a word boundary, and
anything containing shell metacharacters (`;`, `&&`, `|`, backticks, `$(...)`)
is refused so an allowed prefix cannot be extended into a second command. Before
the system's own elevation prompt — which does not say what is about to run, and
may cache your credential afterwards — the app shows the exact command and asks.

Elevation goes through each platform's native mechanism: the macOS password
dialog (`osascript`), polkit's authentication dialog on Linux (`pkexec`, present
on every desktop distribution), and UAC on Windows. One platform difference: on
Windows an elevated command's output cannot stream line-by-line into the app —
it arrives in full when the command finishes.

```json
{
  "sudo": {
    "enabled": true,
    "allowed_commands": ["softwareupdate", "brew install"],
    "confirm": true
  }
}
```

Set `confirm` to `false` only if your app already asks the user itself.

### Drag & drop from the desktop

Files dragged from the Finder or Explorer onto any app window reach your page
with their real paths — something a browser never gives you. The drop counts as
consent, like a dialog pick: the dropped files (and folders, with their
contents) become readable through the filesystem bridge for the session.

Subscribe from a Stimulus controller with plain DOM events:

```js
// data-action="desktop-rails:drop@document->importer#filesDropped"
filesDropped(event) {
  const { paths, position } = event.detail;
  paths.forEach((path) => DesktopRails.fs.read(path));
}
```

`desktop-rails:drag-enter` and `desktop-rails:drag-leave` fire around it for
hover styling, or use the callback API: `DesktopRails.dragDrop.onDrop(cb)`,
`.onEnter(cb)`, `.onLeave(cb)`.

### Window

Layout, zoom and scrolling belong in CSS. The window around them does not, so
the shell exposes it:

```js
await DesktopRails.window.resize(1200, 900);
await DesktopRails.window.fullscreen(true);
await DesktopRails.window.center();
await DesktopRails.window.alwaysOnTop(true);
const { width, height, isMaximized } = await DesktopRails.window.state();
```

Also `minimize()`, `unminimize()`, `maximize()`, `unmaximize()`,
`toggleMaximize()` and `focus()`.

`resize` answers to the app's config rather than to the page: a window declared
`"resizable": false` refuses, and the `min_width` and `min_height` you set win
over a smaller request. A page cannot shrink the window to something nobody can
use, and the size it actually got comes back in the response.

The same component is reachable from Ruby, over the control channel, so a
background job can move the window with no page involved:

```ruby
DesktopRails::Native.call("window", "resize", width: 1200, height: 900)
DesktopRails::Native.call("window", "fullscreen", enabled: true)
```

The config's rules apply there too, and a refusal raises
`DesktopRails::Native::CallFailed`. See `packaging/CONTROL_CHANNEL.md`.

### Clipboard

The browser clipboard API needs a user gesture and a focused document; the
native clipboard does not. `DesktopRails.clipboard.readText()` returns what any
application put there (`null` when it holds no text), and `.writeText(text)`
sets it — from a Turbo Stream callback, a timer, wherever:

```js
const text = await DesktopRails.clipboard.readText();
await DesktopRails.clipboard.writeText("INV-2024-001");
```

Ordinary copy and paste inside the page keeps working through the webview as
in any browser.

`readText()` is refused unless the config allows it — the clipboard is where
passwords and one-time codes sit, and a browser only gives a page the clipboard
on a paste the user makes:

```json
{ "clipboard": { "read": true } }
```

### Launch at login

Offer a toggle in your app's settings page; the shell records the choice with
the OS — a Launch Agent on macOS, the registry `Run` key on Windows, an XDG
autostart entry on Linux:

```js
// A Stimulus controller behind a checkbox
async toggle(event) {
  if (event.target.checked) await DesktopRails.autostart.enable();
  else await DesktopRails.autostart.disable();
}

async connect() {
  this.checkboxTarget.checked = await DesktopRails.autostart.isEnabled();
}
```

It is deliberately not a config key: registering login items silently is how
apps end up on "why does this start with my computer" lists. Ask first.

### Opening files with your app

Declare the file types your app owns in `tauri.conf.json`, and the OS offers
your app for them — double-click, "Open With…", drop on the dock icon:

```json
{
  "bundle": {
    "fileAssociations": [
      { "ext": ["csv"], "description": "Data import", "role": "Viewer" }
    ]
  }
}
```

Opened files arrive as a `desktop-rails:file-open` DOM event with
`event.detail.paths`, whether the app was already running or was launched by
the double-click — a launch queues the paths until your page is up. Like a
dialog pick, being asked to open a file grants it for reading through the
filesystem bridge.

```js
// data-action="desktop-rails:file-open@document->importer#fileOpened"
async fileOpened(event) {
  const { content } = await DesktopRails.fs.read(event.detail.paths[0]);
}
```

### Dev Inspector

In development, press **Cmd/Ctrl+Shift+D** to open the Dev Inspector — an in-app
overlay that shows:

- **Components** — every available bridge component, with a copy-pasteable
  Rails + Stimulus snippet, and which are active on the current page
- **Messages** — a live log of web↔native bridge traffic
- **Navigation** — the path-configuration presentation applied to the current URL
- **Shell** — platform, arch, version, and server URL

Enable it from the Rails gem (added by the installer in development):

```ruby
# config/initializers/desktop_rails.rb
config.inspector_enabled = Rails.env.development?
```

```erb
<%# app/views/layouts/application.html.erb, in <head> %>
<%= desktop_rails_inspector_meta_tag %>
```

Or flip it on against any build without a rebuild:
`localStorage.setItem("td:inspector", "1")`.

### JavaScript Example

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends DesktopRails.stimulusBridge(Controller, "notification") {
  notify(event) {
    this.sendBridge("show", {
      title: "New Message",
      body: event.target.dataset.body,
      id: "message"
    })
  }

  // Everything the shell reports for this component, e.g. { event: "click", data: { id } }
  receiveBridge(message) {
    if (message.event === "click") Turbo.visit("/messages")
  }
}
```

### Desktop-only templates

Requests from the desktop app carry a Rails variant, so an entire template can be
written for it instead of branching inside a shared one:

```
app/views/orders/show.html.erb           # everyone
app/views/orders/show.html+desktop.erb   # the desktop app
```

Layouts too (`layouts/application.html+desktop.erb`). Rails falls back to the
plain template wherever no variant exists, so it costs nothing until you add one.
Rename it with `config.variant`, or set it to `nil` to leave variants alone.

### Rails View Helpers

```erb
<%# Attach bridge data attributes to any element %>
<%= tag.button "Export PDF",
    **desktop_rails_bridge("menu-item",
      title: "Export PDF",
      shortcut: "Cmd+E"
    ) %>
```

The helper only writes `data-desktop-rails-bridge-*` attributes for your own
Stimulus controller to read; nothing registers a menu item until that
controller calls `DesktopRails.menu.add` (or `sendBridge("register", …)`).

## Rails Gem

The `desktop-rails` gem gives your Rails app awareness of the desktop shell.

| Helper | Description |
|---|---|
| `desktop_rails_app?` | Returns `true` if request comes from Desktop Rails |
| `desktop_rails_platform` | Returns `"macos"`, `"windows"`, `"linux"`, or `nil` |
| `desktop_rails_arch` | Returns `"aarch64"`, `"x86_64"`, or `nil` |
| `desktop_rails_only { }` | Renders block only inside the desktop app |
| `turbo_web_only { }` | Renders block only for web (non-desktop) users |
| `desktop_rails_bridge(component, **opts)` | Outputs bridge data attributes |

## Comparison

| Concept | turbo-ios | turbo-android | Desktop Rails |
|---|---|---|---|
| Shell runtime | WKWebView (Swift) | WebView (Kotlin) | Tauri WebView (Rust) |
| Path configuration | JSON, last-match-wins | JSON, last-match-wins | JSON, last-match-wins |
| Bridge / native comms | Strada | Strada | BridgeComponent |
| JS injection | WKUserScript | evaluateJavascript | on_page_load + eval |
| Rails gem | turbo-rails | turbo-rails | desktop-rails |
| Web engine | System WebKit | System WebView | System webview (WebKit, WebView2, WebKitGTK) |
| Download size | — | — | Shell 21.6–31.6 MB; a bundled app adds Ruby and its gems |
| Platforms | iOS, iPadOS | Android | macOS, Windows, Linux |

The sizes are measured rather than estimated. The shells in the
[v0.3.0.pre3 release](https://github.com/DonsWayo/desktop-rails/releases/tag/v0.3.0.pre3)
are 21.6 MB (Windows), 22.6 MB (macOS Apple Silicon), 23.8 MB (macOS Intel) and
31.6 MB (Linux). A bundled app also carries a relocatable Ruby and every gem the
app needs, so it is far larger: after pruning, a freshly generated Rails 8.1 app
packages to 167 MB on macOS and 200 MB on Linux in
[fresh-app.yml](.github/workflows/fresh-app.yml). Hosted mode ships the shell
alone.

## Custom App Icon

This applies to the shell you build with Tauri for hosted mode. A bundle from
`bin/rails desktop:package` does not carry a custom icon yet.

The shell ships with the default desktop-rails icon (in `src-tauri/icons/`). To use your own, run
Tauri's icon generator on a single source image — it produces every size and format
(`.png`, macOS `.icns`, Windows `.ico`, and mobile sets):

```bash
npm run tauri icon path/to/your-icon.png
# or:  cargo tauri icon path/to/your-icon.png
```

Use a **square PNG, 1024×1024, with a transparent background**. The generator overwrites
`src-tauri/icons/`, and `tauri.conf.json`'s `bundle.icon` already points at those files — so the next
`cargo tauri build` (or a run of the Release workflow) uses your icon automatically. No config changes needed.

Prefer to do it by hand? Replace the files in `src-tauri/icons/` listed under `bundle.icon`.

**Starting a new app?** Brand it from the start — the CLI generates your icon during scaffolding.
The CLI is not on npm, so run it from GitHub:

```bash
npx github:DonsWayo/desktop-rails new myapp --icon ./logo.png
```

## Distribution

A bundled app is built by `bin/rails desktop:package` (see [Quick start](#quick-start)); the bundle
in `.desktop-rails/dist/` is what you hand out.

For hosted mode, build installers of the shell for macOS, Windows, and Linux from
**Actions → Release → Run workflow** — the [release workflow](.github/workflows/release.yml) builds
each OS and attaches the installers to a draft GitHub Release.

Pushing a `v*` tag named after the gem version publishes something else: the prebuilt interpreter
and shell that `bin/rails desktop:runtime` and `desktop:shell` download, built by
[release-prebuilt.yml](.github/workflows/release-prebuilt.yml):

```bash
git tag v0.3.0.pre3 && git push origin v0.3.0.pre3
```

See **[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)** for local builds, using it in your own app,
and the optional signing / auto-update setup.

## Project Structure

```
desktop-rails/
├── src/                    # JavaScript (desktop-rails.js)
├── src-tauri/              # Rust / Tauri shell
│   └── src/
│       ├── main.rs         # App entry point
│       ├── security.rs     # Origin, filesystem and sudo policy
│       ├── navigation.rs   # Visit proposals & path config routing
│       ├── bridge.rs       # Bridge dispatch
│       ├── shell_bridge.rs # Process spawning
│       ├── fs_bridge.rs    # Scoped filesystem access
│       ├── sudo_bridge.rs  # Privileged commands
│       ├── config.rs       # Path configuration
│       └── window.rs       # Window management & app config
├── desktop-rails/          # Rails gem
├── examples/notes/         # Example app, packaged in CI
├── packaging/              # Runtime build and pack scripts
├── cli/                    # CLI scaffolding tool
├── templates/              # Project templates
├── test/                   # Tests
└── docs/                   # Documentation
```

## License

MIT — see [LICENSE](LICENSE) for details.

---

<p align="center">
  Built with <a href="https://tauri.app">Tauri</a>, <a href="https://hotwired.dev">Hotwire</a>, and <a href="https://rubyonrails.org">Ruby on Rails</a>.
</p>

# Building a real app with Turbo Desktop

> Written before the fork was renamed from Turbo Desktop to desktop-rails, so it
> uses the old names on purpose. The old gem name it mentions still belongs to
> the upstream project on RubyGems.

Following the documentation literally, as a new user would, and recording every
place it breaks or needs knowledge the docs do not give.

## Findings

1. **The documented gem name installs someone else's old gem, silently.** The
   README says `gem "turbo_desktop-rails"`. That name is published on
   rubygems.org as 0.1.1 by RaiderHQ (aguspe, the upstream author), released
   2026-07-27. `bundle install` succeeds, and the user gets a gem with **none**
   of what the README documents: no `TurboDesktop::Native`, no packaging, no rake
   tasks, no `data_dir`. No error, just a mismatch between the docs and the code
   they installed, discovered later as `NoMethodError`.

   This is worse than a failed install, and it is structural rather than a typo:
   the fork cannot publish under a name upstream owns. It needs its own gem name
   before anyone outside this repository can use it.

2. **The generator leaves the database to the user, with no example.** It prints
   "Add a `desktop:` section to config/database.yml ... point it at
   TurboDesktop.data_dir". It does not write that section, and it does not show
   what one looks like. A user has to know that ERB in database.yml can call a
   gem constant, and invent:

   ```yaml
   desktop:
     <<: *default
     database: <%= TurboDesktop.data_dir(create: true).join("ledger.sqlite3") %>
   ```

   That guess works. But skipping the step fails at boot with Rails' own
   `The desktop database is not configured for the desktop environment`, which
   never mentions Turbo Desktop or `data_dir`, so the connection to a generator
   message the user may have scrolled past is theirs to make. The generator knows
   everything needed to write this section itself.

3. **Every Rails command hung forever in the desktop environment.** Fixed in the
   framework. `RAILS_ENV=desktop bin/rails db:migrate` never returned. The engine
   read the handshake from stdin in *every* Rails process whenever stdin was not a
   terminal, but only the process the shell spawns ever receives one. CI jobs,
   cron, Docker without `-t`, foreman and most IDE run configurations all give a
   process an open pipe that never sends a line, so `gets` blocked indefinitely.

   A deploy script running migrations would simply hang. The shell now sets
   `TURBO_DESKTOP_HANDSHAKE=stdin` on the child it spawns, and nothing else reads
   stdin. This is the most serious finding so far, and no test of the framework
   could have caught it, because every test drove the handshake deliberately.

4. **Every app shipped with no CSS and no JavaScript.** The generated desktop
   environment sets `public_file_server.enabled = true` and says in a comment that
   "assets are precompiled into the bundle". Nothing in the gem ever runs
   `assets:precompile` — the word appears once, in that comment. So every asset
   404s: the page renders server-side, but Turbo and Stimulus never boot, and a
   form submit does a full page load instead of a Turbo Stream.

   This defeats the whole point of the framework, and it is invisible to every
   existing test because none of them loaded a page with assets in it.

5. **Not ours, but it blocks any Rails 8.1.3.1 app today.** A fresh `rails new`
   resolves `json 3.0.2`, which is incompatible with ActiveSupport 8.1.3.1:
   `ActiveSupport::JSON.decode` raises `ArgumentError`, so decrypting the session
   cookie fails and every form POST returns 500. It reproduces in plain
   development with no Turbo Desktop involved. Workaround: `gem "json", "< 3"`.

6. **The error's own fix points at a gem that does not exist.** Packaging without
   a runtime fails with a good message, and suggests either `bin/rails
   desktop:runtime` or `bundle add turbo_desktop-runtime`. The first works, after
   roughly forty minutes. The second returns 404 on rubygems.org: the platform gem
   was built and tested locally but never published. The same root cause as
   finding 1 — nothing outside this repository is installable yet.

7. **`desktop:package` built and signed an app that could not start.** Fixed in
   the framework. It found no gems — a normal Rails app keeps them in the
   development Ruby's gem path, not `vendor/bundle` — printed `gems: (none — the
   bundle will use the runtime's own)` as though that were fine, then reported
   success and "signature verifies" over a bundle that died on `require "rack"`.

   The acceptance test in CI never caught it, because it installed gems by hand
   and passed `--gems` explicitly. It never exercised the path a user takes.

   Now `desktop:gems` installs the app's gems using the interpreter that ships, so
   native extensions compile against what the bundle carries, and packaging
   refuses outright to build a bundle with no gems.

   Getting there hit a second trap: `bin/rails` runs with Bundler loaded, and a
   child `bundle install` inherited `RUBYOPT` and `BUNDLE_*`, resolving against
   the parent's gems and failing from the development Ruby's Bundler even though
   another interpreter was asked to run. It needs `Bundler.with_unbundled_env`.

8. **Any `path:` or `git:` gem breaks the packaged app.** The Gemfile's relative
   path points outside the bundle:
   `The path .../App.app/Contents/turbo_desktop/turbo_desktop-rails does not
   exist (Bundler::PathError)`. Path gems are ordinary for local engines and
   monorepos — and because this gem is not published (finding 1), every user of
   the fork has one, so every packaged app hits this.

## Where it landed

A real Rails 8.1 app — Hotwire, SQLite, a Stimulus controller — packaged with
`bin/rails desktop:package`, boots from inside the signed bundle on its
relocated interpreter. Driven with a real browser in WebKit (the WKWebView
engine) and Chromium, from inside the package:

- the page renders and the environment is detected
- Turbo and Stimulus boot
- a form submit prepends the row through a Turbo Stream, with no page load
- the counter updates in place
- the packaged app reads the same database `desktop:run` wrote, in the OS data
  directory, so data persists between the two
- the Stimulus controller runs, and says there is no native bridge in a browser
- no JavaScript errors

Findings 3, 4, 7 and 8 were bugs in the framework and are fixed. None of them
was caught by the framework's own tests, all of which passed throughout —
because every test drove the handshake on purpose, loaded no page with assets,
and fed gems to the packer by hand. Building a real app was the only thing
that found them.

## Still open

- **Nothing is installable from outside this repository.** Findings 1 and 6: the
  gem name belongs to upstream, and the runtime gem was never published. Until
  the fork has its own gem name, every user needs `path:`, which is why
  finding 8 had to be fixed.
- **The generator should write the `desktop:` database section itself**
  (finding 2) rather than print an instruction with no example.
- **Not tested here: the GUI window.** This machine can no longer launch a GUI
  bundle after a long session, so the UI was driven through a browser against
  the packaged server. CI launches the shell on clean runners, but not with this
  app. The native bridge from inside a real window is unverified.
- **Not tested here: the native call.** In a browser the bridge is absent by
  design, so "Notify from native" has only been proven to degrade correctly.

## Earlier notes, from before 4 and 5 were dealt with



Driven with a real browser in both WebKit (the WKWebView engine) and Chromium:

- the page renders and the environment is detected
- Turbo and Stimulus boot
- submitting the form prepends the new row via a Turbo Stream, with no page load
- the counter updates in place, and data persists across sessions in SQLite
- the Stimulus controller runs, and correctly reports there is no native bridge
  in a plain browser
- no JavaScript errors

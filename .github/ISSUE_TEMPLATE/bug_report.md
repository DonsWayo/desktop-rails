---
name: Bug report
about: Report something that isn't working as expected
title: "[Bug]: "
labels: [bug]
---

## What happened

<!-- A clear description of the bug. -->

## What you expected

<!-- What should have happened instead. -->

## Steps to reproduce

1.
2.
3.

## Environment

- **OS + version:** <!-- e.g. macOS 15.1 (arm64), Windows 11, Ubuntu 24.04 -->
- **Mode:** <!-- bundled (bin/rails desktop:package) or hosted (the shell opening a server you run) -->
- **desktop-rails version or commit:** <!-- the gem's DesktopRails::VERSION, or the commit in Gemfile.lock -->
- **Ruby + Rails version:** <!-- of the app; a bundled app runs on the Ruby desktop:runtime downloaded -->
- **Shell:** <!-- downloaded by desktop:shell, or built from a checkout (which commit) -->

## `desktop-rails.config.json`

<!-- Hosted mode: paste your config (redact anything private). A bundled app writes its own. -->

```json

```

## Logs / errors

<!-- Output of the rake task, the Rails log in the app's data directory (log/desktop.log), a Rust panic, or the Dev Inspector "Messages" panel. -->


```

```

## Additional context

<!-- Screenshots, path-configuration rules, or anything else that helps. -->

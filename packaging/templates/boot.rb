# Boot Puma from config.ru on a port the OS picks, and write one line of
# handshake where the shell can read it. See pack.sh for why `rails server` is
# avoided.
require "json"
require "rack"
require "puma"
require "puma/configuration"
require "puma/launcher"

# The environment the app was built for, when it has one.
#
# The launcher exports RAILS_ENV=production, which is the only safe default for
# a bundle that has no desktop environment. When one has been generated — it
# eager loads, allows the loopback host and nothing else, and keeps jobs in
# process so a forking supervisor cannot outlive the window — that is the
# environment to boot. DESKTOP_RAILS_ENV overrides both.
if (desktop_env = ENV["DESKTOP_RAILS_ENV"])
  ENV["RAILS_ENV"] = desktop_env
elsif File.exist?(File.expand_path("config/environments/desktop.rb", __dir__))
  ENV["RAILS_ENV"] = "desktop"
end

# Keep a private handle on the real stdout, then point $stdout at stderr.
# Everything Puma prints — the banner especially — goes to stderr, and the
# handshake channel stays clean. Doing it here rather than through Puma's
# log_writer keeps this independent of Puma's API, which has moved around.
handshake = $stdout.dup
handshake.sync = true
$stdout.reopen($stderr)

# bootsnap, which every new Rails app requires from config/boot.rb, caches
# under tmp/cache beside config/ unless told otherwise. That is inside the
# bundle: it breaks a signed .app's seal on macOS and fails outright wherever
# the app is installed read-only. The data directory is the app's to write.
if (data_dir = ENV["DESKTOP_DATA_DIR"]) && !data_dir.empty?
  ENV["BOOTSNAP_CACHE_DIR"] ||= File.join(data_dir, "tmp", "cache")
end

app, _ = Rack::Builder.parse_file(File.expand_path("config.ru", __dir__))

# Bring the app's databases up to date before Puma accepts a request. A packaged
# app on a fresh machine starts with an empty data directory, and after an update
# with last version's schema. Guarded, because a bundle may carry an app that
# does not use the gem. See DesktopRails::Database.
DesktopRails::Database.prepare! if defined?(DesktopRails::Database)

# config_files "-" stops Puma from loading config/puma.rb, which it otherwise
# does whenever the working directory has one. That file configures the app's
# own deployment, not this server: Rails 7.1 generates one that writes a
# pidfile to tmp/pids, which aborts the boot inside a read-only bundle, and any
# app's may add workers, plugins or a port of its own. Everything this server
# needs is set here.
config = Puma::Configuration.new(config_files: [ "-" ]) do |c|
  c.bind "tcp://127.0.0.1:0"     # the OS picks, which removes the pick-a-port race
  c.app app
  c.workers 0                    # one process to supervise, and one to reap
  c.threads 1, 5
  c.log_requests false
end

launcher = Puma::Launcher.new(config)

# Puma 8 renamed on_booted to after_booted, and the bound port comes from
# binder.connected_ports — binder.full_urls does not exist. An exception raised
# in this hook is swallowed by Puma's event loop, so it is reported explicitly
# rather than leaving a server running that never announced itself.
hook = launcher.events.respond_to?(:after_booted) ? :after_booted : :on_booted
launcher.events.public_send(hook) do
  begin
    port = launcher.binder.connected_ports.first
    raise "Puma bound no TCP port" unless port
    handshake.puts JSON.generate(protocol: "1.0", url: "http://127.0.0.1:#{port}", pid: Process.pid)
  rescue => e
    warn "[boot] could not announce the server: #{e.class}: #{e.message}"
    Process.exit!(1)
  end
end

# The rule that prevents an orphaned server: exit when the parent closes stdin.
# It is the only layer that survives the parent being force-quit, since no shell
# code runs then. Skipped when stdin is not a pipe, so the bundle stays runnable
# by hand for debugging.
if $stdin.stat.pipe? || !$stdin.tty?
  Thread.new do
    $stdin.read
    Process.exit!(0)
  end
end

launcher.run

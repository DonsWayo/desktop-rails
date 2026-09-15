require "bundler/setup"
require "minitest/autorun"
require "rails/generators"
require "rails/generators/test_case"

# Load the generator
require_relative "../../lib/generators/turbo_desktop/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests TurboDesktop::Generators::InstallGenerator
  destination File.expand_path("../tmp", __dir__)

  setup do
    prepare_destination
    # Create a minimal routes.rb for the route injection
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(
      File.join(destination_root, "config", "routes.rb"),
      "Rails.application.routes.draw do\nend\n"
    )
  end

  test "creates initializer file" do
    run_generator
    assert_file "config/initializers/turbo_desktop.rb"
  end

  test "initializer contains TurboDesktop.configure block" do
    run_generator
    assert_file "config/initializers/turbo_desktop.rb", /TurboDesktop\.configure do \|config\|/
  end

  test "initializer contains path_configuration" do
    run_generator
    assert_file "config/initializers/turbo_desktop.rb", /config\.path_configuration/
  end

  test "initializer contains all presentation types in comments" do
    run_generator
    assert_file "config/initializers/turbo_desktop.rb" do |content|
      assert_match(/"default"/, content)
      assert_match(/"modal"/, content)
      assert_match(/"new_window"/, content)
      assert_match(/"replace"/, content)
      assert_match(/"native"/, content)
      assert_match(/"none"/, content)
    end
  end

  test "mounts engine in routes.rb" do
    run_generator
    assert_file "config/routes.rb", /mount TurboDesktop::Engine => "\/turbo-desktop"/
  end

  test "does not duplicate route on second run" do
    run_generator
    run_generator
    assert_file "config/routes.rb" do |content|
      matches = content.scan(/mount TurboDesktop::Engine/)
      assert_equal 1, matches.length, "Route should appear exactly once"
    end
  end

  test "initializer contains default rules" do
    run_generator
    assert_file "config/initializers/turbo_desktop.rb" do |content|
      assert_match(/patterns: \["\/"\]/, content)
      assert_match(/patterns: \["\/new\$", "\/edit\$"\]/, content)
      assert_match(/screenshots_enabled: false/, content)
    end
  end

  # ─── The desktop environment ─────────────────────────────────────────────

  test "creates the desktop environment" do
    run_generator
    assert_file "config/environments/desktop.rb"
  end

  test "the desktop environment eager loads and does not reload" do
    # The bundle cannot be edited while it runs, so watching for changes is
    # cost with no benefit, and eager loading moves an autoload error to boot
    # rather than to a page the user has already opened.
    run_generator
    assert_file "config/environments/desktop.rb" do |content|
      assert_match(/config\.eager_load = true/, content)
      assert_match(/enable_reloading = false/, content)
    end
  end

  test "the desktop environment allows loopback and nothing else" do
    run_generator
    assert_file "config/environments/desktop.rb" do |content|
      assert_match(/config\.hosts = \[ "127\.0\.0\.1", "localhost", "\[::1\]" \]/, content)
      refute_match(/config\.hosts\.clear/, content,
                   "an empty hosts list would also accept somebody else's Host header")
    end
  end

  test "the desktop environment runs jobs in process" do
    # A forking supervisor is the most effective way to orphan a server: the
    # shell closes stdin, the child exits, and its forked workers keep the port.
    run_generator
    assert_file "config/environments/desktop.rb", /config\.active_job\.queue_adapter = :async/
  end

  test "the desktop environment writes outside the read-only bundle" do
    run_generator
    assert_file "config/environments/desktop.rb" do |content|
      assert_match(/TurboDesktop\.data_dir\(create: true\)/, content)
      assert_match(/config\.paths\["tmp"\]/, content)
      assert_match(/config\.secret_key_base = TurboDesktop\.secret_key_base/, content)
    end
  end

  test "the desktop environment is valid ruby" do
    run_generator
    path = File.join(destination_root, "config/environments/desktop.rb")
    assert system(RbConfig.ruby, "-c", path, out: File::NULL, err: File::NULL),
           "config/environments/desktop.rb does not parse"
  end

  # ─── bin/desktop-boot ────────────────────────────────────────────────────

  test "creates an executable boot script" do
    run_generator
    assert_file "bin/desktop-boot"
    assert File.executable?(File.join(destination_root, "bin/desktop-boot")),
           "the shell spawns this directly, so it has to be executable"
  end

  test "the boot script is valid ruby" do
    run_generator
    path = File.join(destination_root, "bin/desktop-boot")
    assert system(RbConfig.ruby, "-c", path, out: File::NULL, err: File::NULL),
           "bin/desktop-boot does not parse"
  end

  test "the boot script keeps the two rules that stop an orphaned server" do
    run_generator
    assert_file "bin/desktop-boot" do |content|
      # One line of JSON on a dup'd real stdout, before Puma is allowed to
      # print anything there.
      assert_match(/handshake = \$stdout\.dup/, content)
      assert_match(/\$stdout\.reopen\(\$stderr\)/, content)
      assert_match(/handshake\.puts JSON\.generate/, content)
      # Exit when the parent closes stdin. It is the only layer that survives
      # the parent being force-quit, since no shell code runs then.
      assert_match(/\$stdin\.read/, content)
      assert_match(/Process\.exit!\(0\)/, content)
      # The OS picks the port, which removes the pick-a-port race.
      assert_match(%r{tcp://127\.0\.0\.1:0}, content)
      # Never `rails server`: railties creates tmp/cache, tmp/pids and
      # tmp/sockets under Rails.root ignoring config.paths, which is EACCES in
      # a read-only bundle. Puma is booted from config.ru instead.
      assert_match(/Puma::Launcher\.new/, content)
      assert_match(/Rack::Builder\.parse_file/, content)
    end
  end

  test "the boot script agrees with the packaging template" do
    # bin/desktop-boot and packaging/templates/boot.rb are the same program in
    # two places. A bug that appeared in only one of them would be a bug nobody
    # could reproduce, so the load-bearing lines are checked against the
    # template the packers actually install.
    template = File.expand_path("../../../packaging/templates/boot.rb", __dir__)
    skip "no checkout at #{template}" unless File.exist?(template)

    packed = File.read(template)
    run_generator
    generated = File.read(File.join(destination_root, "bin/desktop-boot"))

    [
      "handshake = $stdout.dup",
      "$stdout.reopen($stderr)",
      "tcp://127.0.0.1:0",
      "c.workers 0",
      "launcher.binder.connected_ports.first",
      "Process.exit!(0)",
      # Both have to select the desktop environment, or the environment the
      # generator writes would apply to `desktop:run` and not to the bundle
      # that actually ships.
      %q(ENV["RAILS_ENV"] = "desktop"),
      "TURBO_DESKTOP_ENV"
    ].each do |line|
      assert_includes packed, line
      assert_includes generated, line, "bin/desktop-boot has drifted from boot.rb on: #{line}"
    end
  end

  test "the boot script finds the app root from bin/" do
    # The packers copy this script to the application root; the generator puts
    # it in bin/. It has to work from both, so the root is found, not assumed.
    run_generator
    assert_file "bin/desktop-boot", /File\.exist\?\(File\.join\(dir, "config\.ru"\)\)/
  end

  test "the boot script selects the desktop environment when there is one" do
    run_generator
    assert_file "bin/desktop-boot" do |content|
      assert_match(/config", "environments", "desktop\.rb"/, content)
      assert_match(/ENV\["RAILS_ENV"\] = "desktop"/, content)
      assert_match(/TURBO_DESKTOP_ENV/, content, "there has to be a way to override it")
    end
  end

  # ─── Opting out ──────────────────────────────────────────────────────────

  test "skipping the desktop environment leaves both files out" do
    run_generator [ "--no-desktop-env" ]
    assert_no_file "config/environments/desktop.rb"
    assert_no_file "bin/desktop-boot"
    assert_file "config/initializers/turbo_desktop.rb"
  end
end

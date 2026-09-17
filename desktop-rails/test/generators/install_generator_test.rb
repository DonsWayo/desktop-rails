require "bundler/setup"
require "minitest/autorun"
require "rails/generators"
require "rails/generators/test_case"
require "minitest/mock"
require "erb"
require "yaml"
require "rails"
require "desktop_rails"

# Load the generator
require_relative "../../lib/generators/desktop_rails/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests DesktopRails::Generators::InstallGenerator
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
    assert_file "config/initializers/desktop_rails.rb"
  end

  test "initializer contains DesktopRails.configure block" do
    run_generator
    assert_file "config/initializers/desktop_rails.rb", /DesktopRails\.configure do \|config\|/
  end

  test "initializer contains path_configuration" do
    run_generator
    assert_file "config/initializers/desktop_rails.rb", /config\.path_configuration/
  end

  test "initializer contains all presentation types in comments" do
    run_generator
    assert_file "config/initializers/desktop_rails.rb" do |content|
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
    assert_file "config/routes.rb", /mount DesktopRails::Engine => "\/desktop-rails"/
  end

  test "does not duplicate route on second run" do
    run_generator
    run_generator
    assert_file "config/routes.rb" do |content|
      matches = content.scan(/mount DesktopRails::Engine/)
      assert_equal 1, matches.length, "Route should appear exactly once"
    end
  end

  test "initializer contains default rules" do
    run_generator
    assert_file "config/initializers/desktop_rails.rb" do |content|
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
      assert_match(/DesktopRails\.data_dir\(create: true\)/, content)
      assert_match(/config\.paths\["tmp"\]/, content)
      assert_match(/config\.secret_key_base = DesktopRails\.secret_key_base/, content)
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
    # bin/desktop-boot and the packager's templates/boot.rb are the same program in
    # two places. A bug that appeared in only one of them would be a bug nobody
    # could reproduce, so the load-bearing lines are checked against the
    # template packaging actually installs.
    template = File.expand_path("../../lib/desktop_rails/packager/templates/boot.rb", __dir__)

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
      "DESKTOP_RAILS_ENV",
      # Both have to bring the schema up to date before Puma binds, or a packaged
      # app on a fresh machine serves 500s from an empty database.
      "DesktopRails::Database.prepare! if defined?(DesktopRails::Database)",
      # Both have to keep bootsnap's cache out of the bundle. CI caught a
      # packaged app writing tmp/cache/bootsnap inside its own read-only tree.
      %q(ENV["BOOTSNAP_CACHE_DIR"] ||= File.join(data_dir, "tmp", "cache"))
    ].each do |line|
      assert_includes packed, line
      assert_includes generated, line, "bin/desktop-boot has drifted from boot.rb on: #{line}"
    end
  end

  test "both boot scripts do things in the order that makes them work" do
    # The bootsnap cache has to be redirected before config/boot.rb requires
    # bootsnap, which happens while config.ru is parsed; the schema can only be
    # prepared once the app has loaded, and has to be before Puma accepts a
    # request.
    template = File.expand_path("../../lib/desktop_rails/packager/templates/boot.rb", __dir__)
    run_generator
    scripts = [ File.read(File.join(destination_root, "bin/desktop-boot")), File.read(template) ]

    scripts.each do |script|
      bootsnap = script.index("BOOTSNAP_CACHE_DIR")
      parse = script.index("Rack::Builder.parse_file")
      prepare = script.index("DesktopRails::Database.prepare!")
      run = script.index("launcher.run")
      assert bootsnap < parse, "the bootsnap cache is redirected after the app has loaded"
      assert parse < prepare, "the schema is prepared before the app has loaded"
      assert prepare < run, "the schema is prepared after Puma starts"
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
      assert_match(/DESKTOP_RAILS_ENV/, content, "there has to be a way to override it")
    end
  end

  # ─── Configuration files keyed by environment ───────────────────────────
  #
  # The generator used to print "add a `desktop:` section to database.yml" and
  # write nothing, and skipping that failed at boot with a message that never
  # mentions this gem. A freshly generated app has to package with no edits.

  RAILS_8_DATABASE_YML = <<~YAML
    default: &default
      adapter: sqlite3
      max_connections: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
      timeout: 5000

    development:
      <<: *default
      database: storage/development.sqlite3

    production:
      primary:
        <<: *default
        database: storage/production.sqlite3
      cache:
        <<: *default
        database: storage/production_cache.sqlite3
        migrations_paths: db/cache_migrate
      queue:
        <<: *default
        database: storage/production_queue.sqlite3
        migrations_paths: db/queue_migrate
      cable:
        <<: *default
        database: storage/production_cable.sqlite3
        migrations_paths: db/cable_migrate
  YAML

  SINGLE_DATABASE_YML = <<~YAML
    default: &default
      adapter: sqlite3
      timeout: 5000

    development:
      <<: *default
      database: storage/development.sqlite3

    production:
      <<: *default
      database: storage/production.sqlite3
  YAML

  def write_config(path, content)
    full = File.join(destination_root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  # database.yml as Rails will read it: ERB first, with the data directory
  # pointed somewhere known.
  def desktop_database_config
    previous = ENV["DESKTOP_DATA_DIR"]
    ENV["DESKTOP_DATA_DIR"] = "/data/dir"
    rendered = ERB.new(File.read(File.join(destination_root, "config/database.yml"))).result
    YAML.safe_load(rendered, aliases: true).fetch("desktop")
  ensure
    ENV["DESKTOP_DATA_DIR"] = previous
  end

  test "mirrors the Rails 8 multi-database layout into the data directory" do
    write_config("config/database.yml", RAILS_8_DATABASE_YML)
    run_generator

    desktop = desktop_database_config
    assert_equal %w[primary cache queue cable], desktop.keys
    assert_equal "/data/dir/app.sqlite3", desktop["primary"]["database"]
    assert_equal "/data/dir/app_cache.sqlite3", desktop["cache"]["database"]
    assert_equal "db/queue_migrate", desktop["queue"]["migrations_paths"]
    assert_equal "db/cable_migrate", desktop["cable"]["migrations_paths"]
    desktop.each_value do |config|
      assert_equal "sqlite3", config["adapter"], "the shared default should be merged in"
    end
  end

  test "writes a single database for a single-database app" do
    write_config("config/database.yml", SINGLE_DATABASE_YML)
    run_generator

    desktop = desktop_database_config
    assert_equal "sqlite3", desktop["adapter"]
    assert_equal "/data/dir/app.sqlite3", desktop["database"]
  end

  test "the database section never creates the data directory" do
    # database.yml is evaluated in every environment. Development and test have
    # no business creating the packaged app's directory on a developer's machine.
    write_config("config/database.yml", SINGLE_DATABASE_YML)
    run_generator
    assert_file "config/database.yml" do |content|
      assert_match(/DesktopRails\.data_dir\.join/, content)
      refute_match(/create: true/, content)
    end
  end

  test "is idempotent over every file it appends to" do
    write_config("config/database.yml", RAILS_8_DATABASE_YML)
    write_config("config/cable.yml", "development:\n  adapter: async\n")
    write_config("config/storage.yml", "local:\n  service: Disk\n  root: storage\n")
    write_config(".gitignore", "/tmp/*\n")
    run_generator
    run_generator

    %w[config/database.yml config/cable.yml config/storage.yml].each do |path|
      assert_file path do |content|
        assert_equal 1, content.scan(/^desktop:/).size, "#{path} gained a second desktop section"
      end
    end
    assert_file ".gitignore" do |content|
      assert_equal 1, content.scan(%r{^/\.desktop-rails/$}).size
    end
  end

  test "leaves a desktop section the app already has alone" do
    write_config("config/database.yml", SINGLE_DATABASE_YML + "\ndesktop:\n  <<: *default\n  database: mine.sqlite3\n")
    run_generator
    assert_file "config/database.yml" do |content|
      assert_equal 1, content.scan(/^desktop:/).size
      assert_includes content, "mine.sqlite3"
    end
  end

  test "a server database gets a note, not a guess" do
    write_config("config/database.yml", <<~YAML)
      default: &default
        adapter: postgresql
      production:
        <<: *default
        database: app_production
    YAML
    output = run_generator
    assert_file "config/database.yml" do |content|
      refute_match(/^desktop:/, content)
    end
    assert_match(/postgresql/, output)
    assert_match(/desktop:/, output)
  end

  test "an app with no database.yml installs with a note" do
    output = run_generator
    assert_no_file "config/database.yml"
    assert_match(/no config\/database\.yml/, output)
  end

  test "broadcasts stay in process" do
    write_config("config/cable.yml", "production:\n  adapter: solid_cable\n")
    run_generator
    assert_file "config/cable.yml" do |content|
      assert_equal({ "adapter" => "async" }, YAML.safe_load(content)["desktop"])
    end
  end

  test "uploads go to the data directory, and the environment selects that service" do
    write_config("config/storage.yml", "local:\n  service: Disk\n  root: storage\n")
    run_generator
    assert_file "config/storage.yml", /desktop:\n  service: Disk\n  root: <%= DesktopRails\.data_dir\.join\("storage"\) %>/
    assert_file "config/environments/desktop.rb", /config\.active_storage\.service = :desktop/
  end

  test "the desktop environment never dumps the schema into the bundle" do
    run_generator
    assert_file "config/environments/desktop.rb", /dump_schema_after_migration = false/
  end

  test "the build directory is ignored" do
    write_config(".gitignore", "/log/*\n")
    run_generator
    assert_file ".gitignore", %r{^/\.desktop-rails/$}
  end

  test "pins json only while Active Support cannot decode with it" do
    write_config("Gemfile", "source \"https://rubygems.org\"\ngem \"rails\"\n")

    DesktopRails::Generators::InstallGenerator.stub(:active_support_decodes_json?, true) do
      run_generator
    end
    assert_file("Gemfile") { |content| refute_match(/gem "json"/, content) }

    DesktopRails::Generators::InstallGenerator.stub(:active_support_decodes_json?, false) do
      run_generator
      run_generator
    end
    assert_file "Gemfile" do |content|
      assert_equal 1, content.scan(/^gem "json", "< 3"$/).size
    end
  end

  # ─── What it says next ───────────────────────────────────────────────────

  # The closing instructions used to lead with `npx desktop-rails init` and
  # `dev`, a flow for a package that is not on npm, before the steps that
  # package what the generator had just set up.
  test "the next steps are the quick start's, in its order" do
    output = run_generator
    steps = %w[desktop:runtime desktop:run desktop:package].map { |task| output.index("bin/rails #{task}") }
    assert steps.all?, "every packaging step should be named:\n#{output}"
    assert_equal steps.sort, steps, "in the order the README gives them"
    refute_match(/npx/, output)
    assert_includes output, "#wrapping-a-server-you-run-yourself"
  end

  # ─── Opting out ──────────────────────────────────────────────────────────

  test "skipping the desktop environment leaves both files out" do
    run_generator [ "--no-desktop-env" ]
    assert_no_file "config/environments/desktop.rb"
    assert_no_file "bin/desktop-boot"
    assert_file "config/initializers/desktop_rails.rb"
  end

  test "skipping the desktop environment does not offer packaging steps it cannot run" do
    output = run_generator [ "--no-desktop-env" ]
    refute_match(/desktop:run/, output)
    assert_includes output, "#wrapping-a-server-you-run-yourself"
  end
end

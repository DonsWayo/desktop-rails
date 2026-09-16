require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"

# Runs the real Linux packer over a sandbox app, rather than asserting on argv.
#
# The unit tests in packaging_test.rb check which flags are passed. What they
# cannot see is what a packer then copies, and that is where a freshly generated
# app broke: pack-linux.sh never vendored path gems or wrote the bundle groups
# the way pack.sh learned to, and every packer copied .desktop-rails/ — the
# interpreter, the gems and the previous build — into the app a second time.
#
# pack-linux.sh is the one that can run anywhere a shell and rsync exist; the
# assertions on pack.sh and pack-windows.ps1 below are about the same lines.
class PackersTest < Minitest::Test
  PACKAGING = File.expand_path("../../packaging", __dir__)

  def setup
    super
    skip "no checkout at #{PACKAGING}" unless File.exist?(File.join(PACKAGING, "pack-linux.sh"))
    skip "rsync is not installed" unless system("command -v rsync", out: File::NULL, err: File::NULL)
  end

  def test_the_linux_packer_ships_the_app_and_nothing_it_must_not
    Dir.mktmpdir do |tmp|
      app = build_app(File.join(tmp, "app"))
      runtime = build_runtime(File.join(tmp, "runtime"))

      output, status = Open3.capture2e(
        { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil },
        "bash", File.join(PACKAGING, "pack-linux.sh"),
        "--app", app, "--runtime", runtime, "--name", "Sandbox",
        "--app-id", "dev.example.sandbox", "--out", File.join(tmp, "dist")
      )
      assert status.success?, "pack-linux.sh failed:\n#{output}"

      packed = File.join(tmp, "dist", "sandbox", "lib", "app")
      assert File.exist?(File.join(packed, "config.ru")), "the app itself was not copied"

      # Build products are copied in their own right, not inside the app.
      refute File.exist?(File.join(packed, ".desktop-rails")),
             ".desktop-rails/ was copied into the app: the runtime, gems and last build, twice"
      # The developer's databases stay on their machine, and so do the
      # credential keys of an app whose desktop environment needs none.
      refute File.exist?(File.join(packed, "storage", "development.sqlite3")),
             "the developer's own database shipped"
      refute File.exist?(File.join(packed, "config", "master.key")), "master.key shipped"
      refute File.exist?(File.join(packed, "config", "credentials", "desktop.key")),
             "a credentials key shipped"
      assert File.exist?(File.join(packed, "config", "credentials.yml.enc")),
             "the exclusions are too broad: the encrypted credentials are app code"

      # A path gem points outside the bundle once the app is moved into it.
      assert File.exist?(File.join(packed, "vendor", "path-gems", "local_engine", "local_engine.gemspec")),
             "the path gem was not vendored:\n#{output}"
      assert_match %r{path: "vendor/path-gems/local_engine"}, File.read(File.join(packed, "Gemfile"))
      assert_match %r{remote: vendor/path-gems/local_engine}, File.read(File.join(packed, "Gemfile.lock"))

      # Gems are installed without these groups, so the app must not ask for them.
      assert_match(/BUNDLE_WITHOUT: "development:test"/,
                   File.read(File.join(packed, ".bundle", "config")))
    end
  end

  def test_an_app_without_a_desktop_environment_keeps_its_credentials_key
    # Packaged in production, the key is the app's only source of a
    # secret_key_base; excluding it there broke the smoke app at boot.
    Dir.mktmpdir do |tmp|
      app = build_app(File.join(tmp, "app"), desktop_env: false)
      runtime = build_runtime(File.join(tmp, "runtime"))

      output, status = Open3.capture2e(
        { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil },
        "bash", File.join(PACKAGING, "pack-linux.sh"),
        "--app", app, "--runtime", runtime, "--name", "Sandbox", "--out", File.join(tmp, "dist")
      )
      assert status.success?, "pack-linux.sh failed:\n#{output}"
      assert File.exist?(File.join(tmp, "dist", "sandbox", "lib", "app", "config", "master.key"))
      refute File.exist?(File.join(tmp, "dist", "sandbox", "lib", "app", ".desktop-rails"))
    end
  end

  def test_every_packer_excludes_the_same_things
    {
      "pack.sh" => [ "/.desktop-rails/", "/storage/", "/config/master.key", "/config/credentials/*.key", "environments/desktop.rb" ],
      "pack-linux.sh" => [ "/.desktop-rails/", "/storage/", "/config/master.key", "/config/credentials/*.key", "environments/desktop.rb" ],
      "pack-windows.ps1" => [ ".desktop-rails", '"storage"', 'config\master.key', 'config\credentials\*.key', 'environments\desktop.rb' ]
    }.each do |script, patterns|
      source = File.read(File.join(PACKAGING, script))
      patterns.each { |pattern| assert_includes source, pattern, "#{script} does not exclude #{pattern}" }
    end
  end

  def test_every_packer_vendors_path_gems_and_writes_the_bundle_groups
    %w[pack.sh pack-linux.sh pack-windows.ps1].each do |script|
      source = File.read(File.join(PACKAGING, script))
      assert_includes source, "vendor-path-gems.rb", "#{script} does not vendor path gems"
      assert_includes source, "BUNDLE_WITHOUT", "#{script} does not write the bundle groups"
    end
  end

  # The Windows launcher named lib\ruby\gems\3.4.0 outright, so the day the
  # runtime became Ruby 4.0 every default gem would have gone missing from
  # GEM_PATH. The directory is the interpreter's ABI version, asked at pack time.
  def test_the_windows_launcher_takes_the_gem_directory_from_the_interpreter
    source = File.read(File.join(PACKAGING, "pack-windows.ps1"))

    refute_match(/gems\\\d+\.\d+\.\d+/, source, "a hardcoded ABI directory breaks with the next Ruby")
    assert_includes source, "RbConfig::CONFIG[%q(ruby_version)]"
    assert_includes source, 'lib\ruby\lib\ruby\gems\$abi"'
  end

  private

  def build_app(root, desktop_env: true)
    FileUtils.mkdir_p(File.join(root, "config", "credentials"))
    if desktop_env
      FileUtils.mkdir_p(File.join(root, "config", "environments"))
      File.write(File.join(root, "config", "environments", "desktop.rb"), "")
    end
    File.write(File.join(root, "config.ru"), "run ->(_) { [200, {}, []] }\n")
    File.write(File.join(root, "config", "master.key"), "0" * 32)
    File.write(File.join(root, "config", "credentials.yml.enc"), "encrypted")
    File.write(File.join(root, "config", "credentials", "desktop.key"), "0" * 32)

    FileUtils.mkdir_p(File.join(root, "storage"))
    File.write(File.join(root, "storage", "development.sqlite3"), "")

    FileUtils.mkdir_p(File.join(root, ".desktop-rails", "gems", "gems", "rack-3.2.7"))
    FileUtils.mkdir_p(File.join(root, ".desktop-rails", "dist", "old"))

    engine = File.join(File.dirname(root), "engines", "local_engine")
    FileUtils.mkdir_p(File.join(engine, "lib"))
    File.write(File.join(engine, "local_engine.gemspec"), "Gem::Specification.new\n")

    File.write(File.join(root, "Gemfile"), <<~GEMFILE)
      source "https://rubygems.org"
      gem "local_engine", path: "../engines/local_engine"
    GEMFILE
    File.write(File.join(root, "Gemfile.lock"), <<~LOCK)
      PATH
        remote: ../engines/local_engine
        specs:
          local_engine (0.1.0)

      GEM
        remote: https://rubygems.org/
        specs:

      DEPENDENCIES
        local_engine!
    LOCK
    root
  end

  # Stands in for the relocatable interpreter: the packer only needs a bin/ruby
  # it can execute, and vendor-path-gems.rb needs it to be a real Ruby.
  def build_runtime(root)
    FileUtils.mkdir_p(File.join(root, "bin"))
    ruby = File.join(root, "bin", "ruby")
    File.write(ruby, "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} \"$@\"\n")
    FileUtils.chmod(0o755, ruby)
    root
  end
end

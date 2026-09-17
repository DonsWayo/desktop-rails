require_relative "test_helper"
require "desktop_rails/bundled_package"
require "base64"
require "fileutils"
require "json"
require "open3"
require "rubygems/package"
require "tmpdir"
require "zlib"

# desktop:package, built for real on every platform and read back.
#
# These replace the shell packers, so what they assert is what those scripts
# encoded, each line of it paid for once: what is copied and what must not be,
# the repairs to the packed copy of the app, the launcher and its environment,
# the config the shell reads, signing inside-out with the entitlements, and the
# archives. Layouts only write files; codesign goes through a runner these tests
# record, and pruning's strip through one that refuses, so every platform's
# package builds on whatever machine runs the suite.
class BundledPackageTest < Minitest::Test
  BundledPackage = DesktopRails::BundledPackage
  InvalidInput = DesktopRails::Packager::InvalidInput

  # Prune's runner: strip "fails" on everything, which leaves files as they
  # are, the way it treats a binary strip refuses.
  class NoStrip
    def capture(_argv, **)
      DesktopRails::Tooling::Command::Result.new(output: "", status: nil)
    end
  end

  def with_inputs(platform: :macos, desktop_env: true, abi: "4.0.0", version: "4.0.7", ruby_line: nil)
    Dir.mktmpdir do |tmp|
      yield({
        tmp: tmp,
        app: build_app(File.join(tmp, "app"), desktop_env: desktop_env, ruby_line: ruby_line),
        runtime: build_runtime(File.join(tmp, "runtime"), platform: platform, abi: abi, version: version),
        gems: build_gems(File.join(tmp, "gems")),
        shell: build_shell(File.join(tmp, platform == :windows ? "desktop-rails.exe" : "desktop-rails")),
        out: File.join(tmp, "dist")
      })
    end
  end

  def package(inputs, platform:, shell: true, runner: nil, **options)
    commands = []
    logged = []
    runner ||= ->(argv) { commands << argv; true }
    package = BundledPackage.new(
      app: inputs[:app], runtime: inputs[:runtime], gems: inputs[:gems],
      shell: shell ? inputs[:shell] : nil, name: "Ledger Pro", app_id: "dev.example.ledger",
      out: inputs[:out], platform: platform, runner: runner, prune_runner: NoStrip.new,
      log: ->(message) { logged << message }, **options
    )
    [ package, package.build, commands, logged ]
  end

  # ─── macOS ───────────────────────────────────────────────────────────────

  def test_macos_is_a_signed_app_with_the_runtime_gems_and_app_in_resources
    with_inputs do |inputs|
      _package, layout, commands, = package(inputs, platform: :macos)
      app = File.join(inputs[:out], "Ledger Pro.app")
      assert_equal app, layout.root.to_s
      resources = File.join(app, "Contents", "Resources")

      assert File.executable?(File.join(app, "Contents", "MacOS", "desktop-rails")), "the shell is the executable"
      assert File.executable?(File.join(resources, "ruby", "bin", "ruby"))
      assert File.exist?(File.join(resources, "gems", "gems", "rack-3.2.7", "lib", "rack.rb"))
      assert File.exist?(File.join(resources, "app", "config.ru"))
      assert_packed_app File.join(resources, "app")

      plist = File.read(File.join(app, "Contents", "Info.plist"))
      assert_includes plist, "<key>CFBundleExecutable</key><string>desktop-rails</string>"
      assert_includes plist, "<key>CFBundleIdentifier</key><string>dev.example.ledger</string>"
      assert_includes plist, "<key>CFBundleShortVersionString</key><string>1.0</string>"

      # The config beside the resources, spawning the launcher, not a Ruby.
      config = JSON.parse(File.read(File.join(resources, "desktop-rails.config.json")))
      assert_equal({ "command" => "../MacOS/launch", "directory" => "." }, config["server"])
      assert_equal "http://127.0.0.1:0", config["server_url"]
      assert_equal "Ledger Pro", config["app_name"]
      refute config.key?("updater"), "no updater block unless both halves were given"

      launcher = File.join(app, "Contents", "MacOS", "launch")
      assert File.executable?(launcher)
      script = File.read(launcher)
      assert_includes script, %(export DESKTOP_DATA_DIR="${DESKTOP_DATA_DIR:-$HOME/Library/Application Support/$id}")
      assert_includes script, %(mkdir -p "$DESKTOP_DATA_DIR"/{tmp,log,storage})
      assert_includes script, %(export GEM_PATH="$GEM_HOME:$here/Resources/ruby/lib/ruby/gems/4.0.0")
      assert_includes script, %(export RAILS_ENV="${RAILS_ENV:-production}")
      assert_includes script, %(exec "$here/Resources/ruby/bin/ruby" "${@:-boot.rb}")
      refute_match(/rails server/, script.lines.reject { |line| line.start_with?("#") }.join)

      # Pruned, and only what a user's machine never reads.
      refute File.exist?(File.join(resources, "ruby", "include")), "headers ship"
      refute File.exist?(File.join(resources, "ruby", "lib", "libruby-static.a")), "static archives ship"
      refute File.exist?(File.join(resources, "gems", "cache", "rack-3.2.7.gem")), ".gem caches ship"
      refute File.exist?(File.join(resources, "gems", "gems", "rack-3.2.7", "test")), "gem test suites ship"
      assert File.exist?(File.join(resources, "gems", "gems", "rack-3.2.7", "lib", "rack", "test", "methods.rb")),
             "rack-test's lib/rack/test is library code and must survive pruning"

      # Inside-out, every signature with the hardened runtime and the
      # entitlements, the loadable binaries allowed to fail one by one.
      entitlements = DesktopRails::Packager::MacApp::ENTITLEMENTS
      base = [ "codesign", "--force", "--timestamp=none", "--options", "runtime", "--entitlements", entitlements, "--sign", "-" ]
      signed = commands.select { |argv| argv[1] == "--force" }.map(&:last)
      assert_equal [
        File.join(resources, "gems", "gems", "puma-7.0.0", "lib", "puma", "puma_http11.bundle"),
        File.join(resources, "ruby", "lib", "libruby.4.0.dylib"),
        File.join(resources, "ruby", "lib", "ruby", "4.0.0", "arm64-darwin", "json", "ext", "parser.bundle"),
        File.join(resources, "ruby", "bin", "ruby"),
        launcher,
        File.join(app, "Contents", "MacOS", "desktop-rails"),
        app
      ], signed, "nested binaries (never the libruby.dylib symlink), the interpreter, the launcher, the shell, the bundle"
      commands.select { |argv| argv[1] == "--force" }.each { |argv| assert_equal base, argv[0...-1] }
      assert_equal [ "codesign", "--verify", "--strict", "--deep", app ], commands.last
    end
  end

  def test_the_entitlements_the_interpreter_needs_ship_in_the_gem
    plist = File.read(DesktopRails::Packager::MacApp::ENTITLEMENTS)
    # Without the first the dlopen of an extension is refused; without the
    # second the kernel kills the process.
    assert_includes plist, "<key>com.apple.security.cs.disable-library-validation</key><true/>"
    assert_includes plist, "<key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>"
  end

  def test_macos_without_a_shell_is_a_server_whose_executable_is_the_launcher
    with_inputs do |inputs|
      _package, layout, commands, = package(inputs, platform: :macos, shell: false)
      assert_includes File.read(layout.contents.join("Info.plist")), "<key>CFBundleExecutable</key><string>launch</string>"
      refute File.exist?(layout.config_path), "with no shell there is nothing to read a config"
      assert_equal 1, commands.count { |argv| argv.last == layout.launcher_path.to_s }, "the launcher is signed once"
    end
  end

  def test_a_nested_binary_that_will_not_sign_does_not_fail_the_package_but_the_bundle_does
    with_inputs do |inputs|
      runner = ->(argv) { !argv.last.end_with?(".bundle") }
      _package, _layout, _commands, logged = package(inputs, platform: :macos, runner: runner)
      assert logged.any? { |line| line.include?("signed 1 of 3 nested binaries") }, logged.inspect
    end

    with_inputs do |inputs|
      runner = ->(argv) { !argv.last.end_with?("/ruby") }
      error = assert_raises(DesktopRails::Packager::CommandFailed) { package(inputs, platform: :macos, runner: runner) }
      assert_match(/codesign failed/, error.message)
    end
  end

  def test_the_updater_is_configured_only_with_both_the_endpoint_and_the_key
    with_inputs do |inputs|
      key = File.join(inputs[:tmp], "updater.pub")
      public_key = "untrusted comment: minisign public key 0123456789ABCDEF\n" \
                   "#{Base64.strict_encode64("Ed" + ("k" * 8) + ("p" * 32))}\n"
      File.write(key, public_key)

      _package, layout, = package(inputs, platform: :macos, version: "1.4.0",
                                          update_url: "https://downloads.example.com/latest.json", update_key: key)
      config = JSON.parse(File.read(layout.config_path))
      assert_equal({ "endpoints" => [ "https://downloads.example.com/latest.json" ],
                     "pubkey" => Base64.strict_encode64(public_key), "current_version" => "1.4.0" }, config["updater"])
      assert_includes File.read(layout.contents.join("Info.plist")), "<string>1.4.0</string>"

      error = assert_raises(InvalidInput) do
        package(inputs, platform: :macos, update_url: "https://downloads.example.com/latest.json")
      end
      assert_match(/unsigned update is worse than none/, error.message)
      assert_raises(InvalidInput) { package(inputs, platform: :macos, update_key: key) }

      File.write(key, "not a key\n")
      assert_raises(InvalidInput) do
        package(inputs, platform: :macos, update_url: "https://downloads.example.com/latest.json", update_key: key)
      end
    end
  end

  def test_codesign_accepts_what_it_is_asked_to_sign
    skip "codesign is macOS only" unless RbConfig::CONFIG["host_os"].match?(/darwin/) && File.executable?("/usr/bin/codesign")

    with_inputs do |inputs|
      FileUtils.cp("/usr/bin/true", File.join(inputs[:runtime], "bin", "ruby"))
      FileUtils.cp("/usr/bin/true", inputs[:shell])
      Dir.glob(File.join(inputs[:tmp], "**", "*.{bundle,dylib}")).reject { |path| File.symlink?(path) }.each do |binary|
        FileUtils.cp("/usr/bin/true", binary)
      end
      runner = ->(argv) { system(*argv, err: File::NULL) }
      _package, layout, = package(inputs, platform: :macos, runner: runner)

      assert system("codesign", "--verify", "--strict", "--deep", layout.root.to_s, err: File::NULL)
      entitlements, = Open3.capture2e("codesign", "-d", "--entitlements", "-", layout.interpreter_path.to_s)
      assert_includes entitlements, "com.apple.security.cs.disable-library-validation"
      assert_includes entitlements, "com.apple.security.cs.allow-unsigned-executable-memory"
    end
  end

  # ─── Linux ───────────────────────────────────────────────────────────────

  def test_linux_is_a_tree_with_the_config_beside_the_binary_and_a_tarball
    with_inputs(platform: :linux) do |inputs|
      _package, layout, commands, = package(inputs, platform: :linux)
      tree = File.join(inputs[:out], "ledger-pro")
      assert_equal tree, layout.root.to_s

      assert File.executable?(File.join(tree, "ledger-pro")), "the shell, renamed after the app"
      assert File.executable?(File.join(tree, "lib", "ruby", "bin", "ruby"))
      assert File.exist?(File.join(tree, "lib", "gems", "gems", "rack-3.2.7", "lib", "rack.rb"))
      assert_packed_app File.join(tree, "lib", "app")

      # Beside the binary: Tauri's resource_dir on Linux is /usr/lib/<Name>
      # whether or not anything is installed there.
      config = JSON.parse(File.read(File.join(tree, "desktop-rails.config.json")))
      assert_equal({ "command" => "bin/ledger-pro", "directory" => "." }, config["server"])

      launcher = File.join(tree, "bin", "ledger-pro")
      assert File.executable?(launcher)
      script = File.read(launcher)
      assert_includes script, %(export DESKTOP_DATA_DIR="${DESKTOP_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/dev.example.ledger}")
      assert_includes script, %(export GEM_PATH="$GEM_HOME:$here/lib/ruby/lib/ruby/gems/4.0.0")
      assert_includes script, %(exec "$here/lib/ruby/bin/ruby" "${@:-boot.rb}")
      assert_includes script, %(readlink -f), "the launcher must resolve itself through a symlink such as AppRun"

      entry = File.read(File.join(tree, "share", "applications", "dev.example.ledger.desktop"))
      assert_includes entry, "Exec=ledger-pro"
      assert_empty commands, "a Linux package needs no other program"

      tarball = layout.artifacts.first
      assert_match(/ledger-pro-linux-.+\.tar\.gz\z/, tarball.to_s)
      entries = read_tar(tarball)
      assert_equal 0o755, entries["ledger-pro/bin/ledger-pro"][:mode] & 0o777
      assert_equal 0o755, entries["ledger-pro/lib/ruby/bin/ruby"][:mode] & 0o777
      assert_equal "libruby.so.4.0", entries["ledger-pro/lib/ruby/lib/libruby.so"][:link],
                   "a symlink in the runtime stays a symlink"
      assert entries.key?("ledger-pro/lib/app/.bundle/config")
      refute entries.keys.any? { |name| name.include?(".desktop-rails") }
    end
  end

  def test_linux_skips_an_appimage_when_appimagetool_is_missing
    with_inputs(platform: :linux) do |inputs|
      DesktopRails::Tooling.stub(:which, nil) do
        _package, layout, commands, logged = package(inputs, platform: :linux, appimage: true)
        assert logged.any? { |line| line.include?("appimagetool is not installed") }, logged.inspect
        assert_empty commands
        refute File.exist?(layout.appimage_dir)
      end
    end
  end

  def test_linux_builds_an_appimage_with_apprun_pointing_at_the_launcher
    with_inputs(platform: :linux) do |inputs|
      DesktopRails::Tooling.stub(:which, "/usr/bin/appimagetool") do
        _package, layout, commands, = package(inputs, platform: :linux, appimage: true)
        assert_equal [ layout.appimage_command ], commands
        assert_equal "bin/ledger-pro", File.readlink(layout.appimage_dir.join("AppRun"))
        assert File.exist?(layout.appimage_dir.join("dev.example.ledger.desktop"))
        assert_match(/Ledger Pro-.+\.AppImage\z/, layout.appimage_path.to_s)
      end
    end
  end

  # ─── Windows ─────────────────────────────────────────────────────────────

  def test_windows_is_a_directory_with_a_cmd_launcher_and_a_zip
    with_inputs(platform: :windows) do |inputs|
      _package, layout, commands, logged = package(inputs, platform: :windows)
      tree = File.join(inputs[:out], "ledger-pro")

      assert File.exist?(File.join(tree, "ledger-pro.exe"))
      assert File.exist?(File.join(tree, "lib", "ruby", "bin", "ruby.exe"))
      assert_packed_app File.join(tree, "lib", "app")
      config = JSON.parse(File.read(File.join(tree, "desktop-rails.config.json")))
      assert_equal({ "command" => "ledger-pro.cmd", "directory" => "." }, config["server"])

      script = File.binread(File.join(tree, "ledger-pro.cmd"))
      assert_equal script.count("\n"), script.scan("\r\n").size, "a batch file wants CRLF throughout"
      assert_includes script, %(set "DESKTOP_DATA_DIR=%LOCALAPPDATA%\\dev.example.ledger")
      assert_includes script, %(set "GEM_PATH=%GEMS%;%HERE%lib\\ruby\\lib\\ruby\\gems\\4.0.0")
      assert_includes script, %("%HERE%lib\\ruby\\bin\\ruby.exe" boot.rb)

      # RubyInstaller's writability probe is disabled in the copy, never in
      # the runtime it came from.
      probe = "lib/ruby/4.0.0/rubygems/defaults/operating_system.rb"
      refute_includes File.read(File.join(tree, "lib", "ruby", probe)), "writable_p"
      assert_includes File.read(File.join(inputs[:runtime], probe)), "writable_p"
      assert logged.any? { |line| line.include?("gem writability probe disabled") }, logged.inspect

      assert_empty commands
      assert_equal [ File.join(inputs[:out], "ledger-pro-windows-x64.zip") ], layout.artifacts.map(&:to_s)
      names = zip_names(layout.artifacts.first)
      assert_includes names, "ledger-pro/ledger-pro.cmd"
      assert_includes names, "ledger-pro/lib/app/.bundle/config"
      refute names.any? { |name| name.include?(".desktop-rails") }
    end
  end

  # The launcher named lib\ruby\gems\3.4.0 outright, so the day the runtime
  # became Ruby 4.0 every default gem would have dropped off GEM_PATH.
  def test_the_windows_gem_directory_comes_from_the_runtime_not_a_literal
    with_inputs(platform: :windows, abi: "3.4.0", version: "3.4.8") do |inputs|
      _package, layout, = package(inputs, platform: :windows)
      script = File.read(layout.launcher_path)
      assert_includes script, %(lib\\ruby\\lib\\ruby\\gems\\3.4.0")
      refute_includes script, "4.0.0"
    end
    template = File.read(File.expand_path("../lib/desktop_rails/packager/templates/launch-windows.cmd.erb", __dir__))
    refute_match(/gems\\\d+\.\d+\.\d+/, template, "a hardcoded ABI directory breaks with the next Ruby")
  end

  def test_an_unfamiliar_writability_probe_stops_the_windows_package
    with_inputs(platform: :windows) do |inputs|
      File.write(File.join(inputs[:runtime], "lib", "ruby", "4.0.0", "rubygems", "defaults", "operating_system.rb"),
                 %(File.write(File.join(Gem.default_dir, "writable_p"), "x")\n))
      error = assert_raises(InvalidInput) { package(inputs, platform: :windows) }
      assert_match(/RubyInstaller/, error.message)
    end
  end

  # ─── what every platform copies, and repairs ─────────────────────────────

  def test_an_app_without_a_desktop_environment_keeps_its_credentials_key
    # Packaged in production, the key is the app's only source of a
    # secret_key_base; excluding it there broke the smoke app at boot.
    with_inputs(platform: :linux, desktop_env: false) do |inputs|
      _package, layout, = package(inputs, platform: :linux)
      packed = layout.bundle_dir.join("app")
      assert File.exist?(packed.join("config", "master.key"))
      assert File.exist?(packed.join("config", "credentials", "desktop.key"))
      refute File.exist?(packed.join(".desktop-rails"))
      refute File.exist?(packed.join("storage", "development.sqlite3"))
    end
  end

  def test_the_developers_own_app_is_never_changed
    with_inputs(platform: :linux, ruby_line: %(ruby "4.0.6")) do |inputs|
      before = Dir.glob("**/*", File::FNM_DOTMATCH, base: inputs[:app]).sort.to_h do |path|
        full = File.join(inputs[:app], path)
        [ path, File.file?(full) ? File.binread(full) : nil ]
      end
      package(inputs, platform: :linux)
      after = Dir.glob("**/*", File::FNM_DOTMATCH, base: inputs[:app]).sort.to_h do |path|
        full = File.join(inputs[:app], path)
        [ path, File.file?(full) ? File.binread(full) : nil ]
      end
      assert_equal before, after
    end
  end

  def test_a_ruby_pinned_to_another_patch_release_is_repaired_in_the_packed_copy
    with_inputs(platform: :linux, ruby_line: %(ruby "4.0.6")) do |inputs|
      _package, layout, _commands, logged = package(inputs, platform: :linux)
      gemfile = File.read(layout.bundle_dir.join("app", "Gemfile"))
      assert_includes gemfile, %(ruby "4.0.7"\n)
      refute_match(/^ruby "4\.0\.6"/, gemfile)
      assert_includes File.read(layout.bundle_dir.join("app", "Gemfile.lock")), "RUBY VERSION\n   ruby 4.0.7\n"
      assert logged.any? { |line| line.include?("Ruby requirement") }, logged.inspect
    end
  end

  def test_a_ruby_the_runtime_cannot_be_stops_the_package_before_anything_is_built
    with_inputs(platform: :linux, ruby_line: %(ruby "~> 3.4")) do |inputs|
      error = assert_raises(InvalidInput) { package(inputs, platform: :linux) }
      assert_match(/requires Ruby ~> 3\.4/, error.message)
      assert_match(/runtime being packaged is Ruby 4\.0\.7/, error.message)
    end
  end

  def test_a_path_gem_that_does_not_exist_is_refused
    with_inputs(platform: :linux) do |inputs|
      FileUtils.rm_rf(File.join(inputs[:tmp], "engines"))
      error = assert_raises(InvalidInput) { package(inputs, platform: :linux) }
      assert_match(%r{\.\./engines/local_engine}, error.message)
    end
  end

  def test_a_rebuild_leaves_nothing_from_the_last_one
    with_inputs(platform: :linux) do |inputs|
      _package, layout, = package(inputs, platform: :linux)
      stale = layout.bundle_dir.join("app", "left-over.txt")
      File.write(stale, "from an earlier build")
      package(inputs, platform: :linux)
      refute File.exist?(stale)
    end
  end

  def test_inputs_that_cannot_be_packaged_are_refused_with_a_reason
    with_inputs(platform: :linux) do |inputs|
      File.delete(File.join(inputs[:app], "config.ru"))
      assert_match(/config\.ru/, assert_raises(InvalidInput) { package(inputs, platform: :linux) }.message)
    end
    with_inputs(platform: :linux) do |inputs|
      FileUtils.rm_rf(File.join(inputs[:runtime], "bin"))
      assert_match(/bin\/ruby/, assert_raises(InvalidInput) { package(inputs, platform: :linux) }.message)
    end
    with_inputs(platform: :linux) do |inputs|
      # The app id is written into a shell script and a directory name.
      package = BundledPackage.new(app: inputs[:app], runtime: inputs[:runtime], name: "Ledger",
                                   app_id: "dev.example/ledger; rm -rf ~", out: inputs[:out], platform: :linux)
      assert_match(/app id/, assert_raises(InvalidInput) { package.build }.message)
    end
  end

  def test_the_boot_script_in_the_package_keeps_bootsnap_out_of_the_bundle
    with_inputs(platform: :linux) do |inputs|
      _package, layout, = package(inputs, platform: :linux)
      boot = File.read(layout.bundle_dir.join("app", "boot.rb"))
      assert_includes boot, %q(ENV["BOOTSNAP_CACHE_DIR"] ||= File.join(data_dir, "tmp", "cache"))
      assert_includes boot, %(c.bind "tcp://127.0.0.1:0")
    end
  end

  private

  def assert_packed_app(packed)
    assert File.exist?(File.join(packed, "boot.rb")), "boot.rb is copied to the app root"

    # Build products are copied in their own right, not inside the app, and
    # development state stays behind at any depth.
    refute File.exist?(File.join(packed, ".desktop-rails")),
           ".desktop-rails/ was copied into the app: the runtime, gems and last build, twice"
    refute File.exist?(File.join(packed, "tmp")), "tmp/ shipped"
    refute File.exist?(File.join(packed, "log")), "log/ shipped"
    refute File.exist?(File.join(packed, ".git")), ".git/ shipped"
    refute File.exist?(File.join(packed, "node_modules")), "node_modules/ shipped"
    refute File.exist?(File.join(packed, "vendor", "javascript", "node_modules")), "a nested node_modules/ shipped"
    # The developer's databases stay on their machine, and so do the
    # credential keys of an app whose desktop environment needs none.
    refute File.exist?(File.join(packed, "storage", "development.sqlite3")), "the developer's own database shipped"
    refute File.exist?(File.join(packed, "config", "master.key")), "master.key shipped"
    refute File.exist?(File.join(packed, "config", "credentials", "desktop.key")), "a credentials key shipped"
    assert File.exist?(File.join(packed, "config", "credentials.yml.enc")),
           "the exclusions are too broad: the encrypted credentials are app code"
    assert File.exist?(File.join(packed, "app", "models", "log.rb")),
           "a file merely named like an excluded directory is app code"

    # A path gem points outside the bundle once the app is moved into it.
    assert File.exist?(File.join(packed, "vendor", "path-gems", "local_engine", "local_engine.gemspec"))
    refute File.exist?(File.join(packed, "vendor", "path-gems", "local_engine", "test")), "a path gem's tests shipped"
    assert_match %r{path: "vendor/path-gems/local_engine"}, File.read(File.join(packed, "Gemfile"))
    assert_match %r{remote: vendor/path-gems/local_engine}, File.read(File.join(packed, "Gemfile.lock"))

    # Gems are installed without these groups, so the app must not ask for them.
    assert_equal %(---\nBUNDLE_WITHOUT: "development:test"\n), File.read(File.join(packed, ".bundle", "config"))
  end

  def build_app(root, desktop_env: true, ruby_line: nil)
    FileUtils.mkdir_p(File.join(root, "config", "credentials"))
    if desktop_env
      FileUtils.mkdir_p(File.join(root, "config", "environments"))
      File.write(File.join(root, "config", "environments", "desktop.rb"), "")
    end
    File.write(File.join(root, "config.ru"), "run ->(_) { [200, {}, []] }\n")
    File.write(File.join(root, "config", "master.key"), "0" * 32)
    File.write(File.join(root, "config", "credentials.yml.enc"), "encrypted")
    File.write(File.join(root, "config", "credentials", "desktop.key"), "0" * 32)
    FileUtils.mkdir_p(File.join(root, "app", "models"))
    File.write(File.join(root, "app", "models", "log.rb"), "")

    { "storage/development.sqlite3" => "", "tmp/cache/bootsnap" => "", "log/development.log" => "",
      ".git/HEAD" => "ref", "node_modules/x/index.js" => "", "vendor/javascript/node_modules/y.js" => "",
      ".desktop-rails/gems/gems/rack-3.2.7/x" => "", ".desktop-rails/dist/old/x" => "" }.each do |path, content|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
    end

    engine = File.join(File.dirname(root), "engines", "local_engine")
    FileUtils.mkdir_p(File.join(engine, "lib"))
    FileUtils.mkdir_p(File.join(engine, "test"))
    File.write(File.join(engine, "local_engine.gemspec"), "Gem::Specification.new\n")

    File.write(File.join(root, "Gemfile"), <<~GEMFILE)
      source "https://rubygems.org"
      #{ruby_line}
      gem "rails"
      gem "local_engine", path: "../engines/local_engine"
      group :development do
        gem "web-console"
      end
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

      RUBY VERSION
         ruby 4.0.6

      BUNDLED WITH
         4.0.3
    LOCK
    root
  end

  # Stands in for the relocatable interpreter: the files packaging reads and
  # moves, in the places a real one has them.
  def build_runtime(root, platform:, abi:, version:)
    major, minor, teeny = version.split(".")
    arch = { macos: "arm64-darwin", linux: "x86_64-linux", windows: "x64-mingw-ucrt" }.fetch(platform)
    files = {
      "bin/#{platform == :windows ? "ruby.exe" : "ruby"}" => "#!/bin/sh\n",
      "lib/ruby/#{abi}/#{arch}/rbconfig.rb" => <<~RB,
        module RbConfig
          CONFIG = {}
          CONFIG["MAJOR"] = "#{major}"
          CONFIG["MINOR"] = "#{minor}"
          CONFIG["TEENY"] = "#{teeny}"
          CONFIG["PATCHLEVEL"] = "0"
          CONFIG["ruby_version"] = "#{abi}"
        end
      RB
      "include/ruby-#{abi}/ruby.h" => "",
      "lib/libruby-static.a" => "",
      "lib/ruby/gems/#{abi}/gems/json-2.9.0/lib/json.rb" => ""
    }
    case platform
    when :macos
      files["lib/libruby.4.0.dylib"] = "mach-o"
      files["lib/ruby/#{abi}/#{arch}/json/ext/parser.bundle"] = "mach-o"
    when :linux
      files["lib/libruby.so.4.0"] = "elf"
    when :windows
      files["lib/ruby/#{abi}/rubygems/defaults/operating_system.rb"] = <<~'RUBY'
        require "ruby_installer/runtime"

        begin
          checkfile = File.join(Gem.default_dir, "/writable_p")
          File.write(checkfile, "")
          File.unlink(checkfile) rescue nil # Raises ENOENT sometimes
        rescue Errno::EACCES
          warn_per_user = true
        end

        RubyInstaller::Runtime.enable_dll_search_paths
      RUBY
    end
    files.each do |path, content|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
    end
    FileUtils.chmod(0o755, File.join(root, "bin", platform == :windows ? "ruby.exe" : "ruby"))
    File.symlink("libruby.4.0.dylib", File.join(root, "lib", "libruby.dylib")) if platform == :macos
    File.symlink("libruby.so.4.0", File.join(root, "lib", "libruby.so")) if platform == :linux
    root
  end

  def build_gems(root)
    {
      "gems/rack-3.2.7/lib/rack.rb" => "",
      "gems/rack-3.2.7/lib/rack/test/methods.rb" => "",
      "gems/rack-3.2.7/test/spec_rack.rb" => "",
      "gems/puma-7.0.0/lib/puma/puma_http11.bundle" => "mach-o",
      "specifications/rack-3.2.7.gemspec" => "",
      "cache/rack-3.2.7.gem" => ""
    }.each do |path, content|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
    end
    root
  end

  def build_shell(path)
    File.write(path, "shell binary")
    FileUtils.chmod(0o755, path)
    path
  end

  def read_tar(path)
    entries = {}
    File.open(path.to_s, "rb") do |file|
      Zlib::GzipReader.wrap(file) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            entries[entry.full_name.delete_suffix("/")] = { mode: entry.header.mode, link: (entry.header.linkname if entry.symlink?) }
          end
        end
      end
    end
    entries
  end

  def zip_names(path)
    bytes = File.binread(path.to_s)
    eocd = bytes.rindex([ 0x06054b50 ].pack("V"))
    count, _size, offset = bytes.byteslice(eocd + 10, 10).unpack("vVV")
    Array.new(count) do
      header = bytes.byteslice(offset, 46).unpack("VvvvvvvVVVvvvvvVV")
      name_length, extra, comment = header.values_at(10, 11, 12)
      name = bytes.byteslice(offset + 46, name_length)
      offset += 46 + name_length + extra + comment
      name.delete_suffix("/")
    end
  end
end

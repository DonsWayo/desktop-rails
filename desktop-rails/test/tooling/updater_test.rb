require_relative "tooling_test_helper"
require "desktop_rails/tooling/updater"
require "json"

class ToolingUpdaterTest < Minitest::Test
  include ToolingTestSupport

  Updater = DesktopRails::Tooling::Updater

  def test_versions_the_plugin_accepts
    %w[1.2.0 v1.2.0 0.3.0-pre.2 1.0.0+build.5 1.0.0-rc.1+sha.abc].each { |v| assert_match Updater::SEMVER, v }
    %w[1.2 1.2.0.pre1 v1 latest].each { |v| refute_match Updater::SEMVER, v }
  end

  def test_targets_the_plugin_recognises
    %w[darwin-aarch64 darwin-x86_64 linux-x86_64 windows-x86_64 windows-i686 linux-armv7].each do |t|
      assert_match Updater::TARGET, t
    end
    # The plugin calls macOS darwin; "macos-aarch64" reads as no update at all.
    %w[macos-aarch64 darwin-arm64 linux windows-x64].each { |t| refute_match Updater::TARGET, t }
  end

  def test_the_host_target_uses_the_plugins_names
    assert_equal "darwin-aarch64", Updater.host_target(host_os: "darwin24", host_cpu: "arm64")
    assert_equal "linux-x86_64", Updater.host_target(host_os: "linux-gnu", host_cpu: "x86_64")
    assert_equal "windows-x86_64", Updater.host_target(host_os: "mingw32", host_cpu: "x64")
    assert_raises(DesktopRails::Tooling::MissingPrerequisite) do
      Updater.host_target(host_os: "linux-gnu", host_cpu: "riscv64")
    end
  end

  def signing(dir, **options)
    artifact = write(File.join(dir, "Ledger.app.tar.gz"), "bundle")
    Updater::Signing.new(artifact: artifact, version: "1.2.0", url: "https://example.com/Ledger.app.tar.gz",
                         target: "darwin-aarch64", env: {}, log: StringIO.new,
                         clock: -> { Time.at(1_789_000_000) }, **options)
  end

  def test_defaults_sit_beside_the_artifact
    Dir.mktmpdir do |dir|
      s = signing(dir)
      assert_equal File.join(dir, "latest.json"), s.manifest
      assert_equal File.join(dir, "Ledger.app.tar.gz.sig"), s.sig
      assert_equal "/keys/ledger.pub", s.public_key("/keys/ledger.key")
    end
  end

  def test_the_trusted_comment_names_the_file_version_and_time
    Dir.mktmpdir do |dir|
      assert_equal "timestamp:1789000000\tfile:Ledger.app.tar.gz\tversion:1.2.0\thashed", signing(dir).trusted_comment
    end
  end

  def test_the_password_comes_from_the_environment_only
    Dir.mktmpdir do |dir|
      s = signing(dir, env: { "DESKTOP_RAILS_SIGNING_PASSWORD" => "hunter2" })
      argv = s.sign_argv(node: "node", cli: "cli.mjs", key: "/k.key")
      assert_equal [ "node", "cli.mjs", "sign", "--key", "/k.key", "--artifact", s.artifact, "--sig", s.sig,
                     "--password", "hunter2" ], argv.first(11)
      assert_equal "", signing(dir).sign_argv(node: "node", cli: "cli.mjs", key: "/k.key")[10],
                   "no password is an empty one, as tauri signer writes it"
    end
  end

  def test_manifest_options_are_passed_only_when_given
    Dir.mktmpdir do |dir|
      argv = signing(dir).manifest_argv(node: "node", cli: "cli.mjs")
      refute_includes argv, "--notes"
      refute_includes argv, "--pub-date"

      argv = signing(dir, notes: "Fixes", notes_file: "/n.md", pub_date: "2026-09-15T10:00:00Z")
             .manifest_argv(node: "node", cli: "cli.mjs")
      assert_equal "Fixes", argv[argv.index("--notes") + 1]
      assert_equal "/n.md", argv[argv.index("--notes-file") + 1]
      assert_equal "2026-09-15T10:00:00Z", argv[argv.index("--pub-date") + 1]
      assert_equal "darwin-aarch64", argv[argv.index("--target") + 1]
    end
  end

  def test_bad_input_is_refused_before_anything_is_signed
    Dir.mktmpdir do |dir|
      assert_match(/semver/, assert_raises(DesktopRails::Tooling::Error) { signing(dir, version: "1.2").validate! }.message)
      assert_match(/--target must be/, assert_raises(DesktopRails::Tooling::Error) { signing(dir, target: "macos-arm64").validate! }.message)
      assert_match(/--url/, assert_raises(DesktopRails::Tooling::Error) { signing(dir, url: "").validate! }.message)
      error = assert_raises(DesktopRails::Tooling::Error) do
        Updater::Signing.new(artifact: File.join(dir, "missing"), version: "1.0.0", url: "https://x", env: {}).validate!
      end
      assert_match(/--artifact/, error.message)
    end
  end

  def test_a_key_from_the_environment_is_written_privately_and_removed
    Dir.mktmpdir do |dir|
      seen = nil
      runner = RecordingRunner.new
      runner.on(->(argv) { argv[2] == "sign" }) do |argv|
        key = argv[argv.index("--key") + 1]
        seen = [ key, File.read(key), File.stat(key).mode & 0o777 ]
      end
      runner.on(->(argv) { argv[2] == "manifest" }, output: "darwin-aarch64\n")
      env = { "DESKTOP_RAILS_SIGNING_KEY" => "untrusted comment: secret", "PATH" => fake_node(dir),
              "DESKTOP_RAILS_UPDATER_CLI" => write(File.join(dir, "cli.mjs")) }

      signing(dir, env: env, runner: runner).sign!
      key, content, mode = seen
      assert_equal "untrusted comment: secret\n", content
      assert_equal 0o600, mode
      refute File.exist?(key), "the key must not outlive the signing"
      # A key handed over this way has no .pub beside it, so nothing is verified
      # unless --public says what against.
      refute(runner.argvs.any? { |argv| argv[2] == "verify" })
    end
  end

  def test_a_missing_key_file_says_how_to_make_one
    Dir.mktmpdir do |dir|
      env = { "PATH" => fake_node(dir), "DESKTOP_RAILS_UPDATER_CLI" => write(File.join(dir, "cli.mjs")) }
      error = assert_raises(DesktopRails::Tooling::Error) do
        signing(dir, env: env, key: File.join(dir, "nope.key"), runner: RecordingRunner.new).sign!
      end
      assert_match(/generate-key/, error.message)
    end
  end

  def test_generating_refuses_to_overwrite_a_key
    Dir.mktmpdir do |dir|
      write(File.join(dir, "updater.key"), "existing")
      error = assert_raises(DesktopRails::Tooling::Error) do
        Updater::KeyGeneration.new(dir: dir, env: {}, runner: RecordingRunner.new, log: StringIO.new).generate!
      end
      assert_match(/--force/, error.message)
      assert_equal "existing", File.read(File.join(dir, "updater.key"))
    end
  end

  # The real signer, when node is here: a key made, a bundle signed, verified
  # and merged into a manifest, through this Ruby and the same .mjs the
  # JavaScript suite and the shell's Rust tests hold to the plugin.
  def test_generate_sign_and_verify_with_the_real_signer
    skip "node is not on PATH" unless DesktopRails::Tooling.which("node")
    skip "no checkout beside the gem" unless Updater.cli_path

    Dir.mktmpdir do |dir|
      env = ENV.to_h.merge("DESKTOP_RAILS_SIGNING_PASSWORD" => "correct horse")
      env.delete("DESKTOP_RAILS_SIGNING_KEY")
      log = StringIO.new
      pubkey = Updater::KeyGeneration.new(dir: File.join(dir, ".signing"), env: env, log: log).generate!
      assert_equal 0o600, File.stat(File.join(dir, ".signing", "updater.key")).mode & 0o777
      assert_includes log.string, pubkey

      signing(dir, env: env, key: File.join(dir, ".signing", "updater.key"), log: log).sign!
      manifest = JSON.parse(File.read(File.join(dir, "latest.json")))
      assert_equal "1.2.0", manifest["version"]
      assert_equal "https://example.com/Ledger.app.tar.gz", manifest.dig("platforms", "darwin-aarch64", "url")
      assert_includes log.string, "Verifying against updater.pub"
      assert_includes log.string, "version:1.2.0"

      wrong = env.merge("DESKTOP_RAILS_SIGNING_PASSWORD" => "wrong")
      assert_raises(DesktopRails::Tooling::CommandFailed) do
        signing(dir, env: wrong, key: File.join(dir, ".signing", "updater.key")).sign!
      end
    end
  end

  private

  def fake_node(dir)
    executable(File.join(dir, "bin", "node"))
    File.join(dir, "bin")
  end
end

require_relative "tooling_test_helper"
require "desktop_rails/tooling/cli"

class ToolingCLITest < Minitest::Test
  include WithoutBundlerInChildren
  include ToolingTestSupport

  CLI = DesktopRails::Tooling::CLI
  EXE = File.expand_path("../../exe/desktop-rails-tool", __dir__)

  def run_cli(*argv, env: {})
    out = StringIO.new
    err = StringIO.new
    status = CLI.start(argv, out: out, err: err, env: env)
    [ status, out.string, err.string ]
  end

  def test_no_command_prints_usage_and_fails
    status, out, = run_cli
    assert_equal 2, status
    assert_includes out, "runtime build"
    assert_includes out, "smoke app"
  end

  def test_an_unknown_command_is_a_usage_error
    status, _, err = run_cli("bogus")
    assert_equal 2, status
    assert_includes err, "unknown command: bogus"
  end

  def test_a_missing_argument_is_a_usage_error_not_a_backtrace
    assert_equal 2, run_cli("runtime", "verify").first
    assert_equal 2, run_cli("runtime", "fetch-windows").first
    assert_equal 2, run_cli("smoke", "shell").first
    assert_equal 2, run_cli("runtime", "build", "--no-such-flag").first
  end

  def test_package_needs_an_app_and_a_runtime
    assert_equal 2, run_cli("package").first
    assert_equal 2, run_cli("package", "--app", "x").first
  end

  # What package-smoke.yml runs in place of pack.sh and pack-linux.sh.
  def test_package_builds_the_package_or_says_why_not
    Dir.mktmpdir do |dir|
      status, _, err = run_cli("package", "--app", File.join(dir, "nope"), "--runtime", dir, "--platform", "linux",
                               "--out", File.join(dir, "dist"))
      assert_equal 1, status
      assert_match(/not a directory/, err)

      app = File.join(dir, "app")
      FileUtils.mkdir_p(app)
      File.write(File.join(app, "config.ru"), "run ->(_) { [200, {}, []] }\n")
      runtime = File.join(dir, "runtime")
      FileUtils.mkdir_p(File.join(runtime, "bin"))
      FileUtils.mkdir_p(File.join(runtime, "lib", "ruby", "4.0.0", "x86_64-linux"))
      File.write(File.join(runtime, "bin", "ruby"), "")
      File.write(File.join(runtime, "lib", "ruby", "4.0.0", "x86_64-linux", "rbconfig.rb"),
                 %(CONFIG["MAJOR"] = "4"\nCONFIG["MINOR"] = "0"\nCONFIG["TEENY"] = "7"\n) +
                 %(CONFIG["PATCHLEVEL"] = "0"\nCONFIG["ruby_version"] = "4.0.0"\n))

      status, out, err = run_cli("package", "--app", app, "--runtime", runtime, "--platform", "linux",
                                 "--name", "Smoke", "--app-id", "dev.desktop-rails.smoke", "--out", File.join(dir, "dist"))
      assert_equal 0, status, err
      assert File.executable?(File.join(dir, "dist", "smoke", "bin", "smoke"))
      assert_match(/smoke-linux-.+\.tar\.gz/, out)
    end
  end

  def test_a_failed_step_is_a_sentence_and_exit_1
    Dir.mktmpdir do |dir|
      status, _, err = run_cli("dmg", File.join(dir, "Missing.app"))
      assert_equal 1, status
      assert_match(/is not a \.app bundle/, err)
    end
  end

  def test_prune_takes_keep_dev_from_the_flag_or_the_environment
    Dir.mktmpdir do |dir|
      doc = write(File.join(dir, "ruby", "share", "ri", "x.ri"))
      archive = write(File.join(dir, "ruby", "lib", "libruby-static.a"))
      assert_equal 0, run_cli("prune", dir, env: { "KEEP_DEV" => "1" }).first
      assert File.exist?(doc)
      refute File.exist?(archive)
      assert_equal 0, run_cli("prune", dir).first
      refute File.exist?(doc)
    end
  end

  def test_the_smoke_app_check_reads_its_data_directory_from_the_environment
    status, out, = run_cli("smoke", "app", "/nonexistent/shell", env: {})
    assert_equal 1, status
    assert_includes out, "DESKTOP_DATA_DIR"
  end

  def test_the_executable_runs_without_a_bundle
    # CI runs it with whatever Ruby the runner has, and no Gemfile.
    output = DesktopRails::Tooling::Command.new.capture([ RbConfig.ruby, EXE, "--help" ], clean_ruby: true)
    assert output.success?, output.output
    assert_includes output.output, "usage: desktop-rails-tool"
  end

  def test_the_executable_ships_in_the_gem
    spec = Gem::Specification.load(File.expand_path("../../desktop-rails.gemspec", __dir__))
    assert_includes spec.files, "exe/desktop-rails-tool"
    assert_includes spec.executables, "desktop-rails-tool"
    %w[command runtime_build runtime_verification windows_runtime prune disk_image notarization updater smoke cli].each do |name|
      assert_includes spec.files, "lib/desktop_rails/tooling/#{name}.rb"
    end
  end
end

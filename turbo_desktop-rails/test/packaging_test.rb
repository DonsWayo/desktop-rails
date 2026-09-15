require_relative "test_helper"
require "turbo_desktop/packaging"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"

# A sandbox that looks like the two directories the packaging workflow needs: a
# checkout of turbo_desktop's packaging/ scripts, and a Rails app to package.
# Building them here rather than pointing at the real repository keeps the
# assertions about *decisions* — which packer, which flags — and not about
# whichever files happen to exist on the machine running the suite.
module PackagingSandbox
  SCRIPTS = %w[
    pack.sh pack-linux.sh pack-windows.ps1 build-runtime.sh fetch-windows-runtime.ps1
  ].freeze

  def with_sandbox(runtime: true, gems: false, shell: false, env: {})
    Dir.mktmpdir do |tmp|
      packaging = File.join(tmp, "packaging")
      FileUtils.mkdir_p(packaging)
      SCRIPTS.each { |s| File.write(File.join(packaging, s), "#!/bin/sh\n") }

      app = File.join(tmp, "app")
      FileUtils.mkdir_p(File.join(app, "bin"))
      File.write(File.join(app, "config.ru"), "run ->(_) {}\n")

      runtime_dir = File.join(tmp, "runtime")
      if runtime
        FileUtils.mkdir_p(File.join(runtime_dir, "bin"))
        File.write(File.join(runtime_dir, "bin", "ruby"), "")
        FileUtils.chmod(0o755, File.join(runtime_dir, "bin", "ruby"))
      end

      gems_dir = File.join(tmp, "gems")
      FileUtils.mkdir_p(gems_dir) if gems

      shell_bin = File.join(tmp, "turbo-desktop")
      if shell
        File.write(shell_bin, "")
        FileUtils.chmod(0o755, shell_bin)
      end

      base = {
        "TURBO_DESKTOP_PACKAGING" => packaging,
        "TURBO_DESKTOP_APP" => app,
        "TURBO_DESKTOP_RUNTIME" => (runtime ? runtime_dir : nil),
        "TURBO_DESKTOP_GEMS" => (gems ? gems_dir : nil),
        "TURBO_DESKTOP_SHELL" => (shell ? shell_bin : nil),
        "TURBO_DESKTOP_DIST" => File.join(tmp, "dist"),
        "TURBO_DESKTOP_BUILD" => File.join(tmp, "build")
      }.merge(env)

      with_env(base) do
        yield({ root: tmp, packaging: packaging, app: app, runtime: runtime_dir,
                gems: gems_dir, shell: shell_bin, dist: File.join(tmp, "dist") })
      end
    end
  end

  def with_env(values)
    # The workflow reads a lot of environment, so a leaked variable would make
    # one test's fixture change another test's answer.
    previous = values.keys.to_h { |k| [ k, ENV[k] ] }
    values.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def on_platform(platform, &block)
    TurboDesktop::Packaging.stub(:platform, platform, &block)
  end

  def flag(argv, name)
    index = argv.index(name)
    index && argv[index + 1]
  end
end

class PackagingScriptResolutionTest < Minitest::Test
  include PackagingSandbox

  def test_environment_variable_points_at_the_scripts
    with_sandbox do |paths|
      assert_equal paths[:packaging], TurboDesktop::Packaging.packaging_dir.to_s
    end
  end

  def test_configuration_points_at_the_scripts
    with_sandbox do |paths|
      with_env("TURBO_DESKTOP_PACKAGING" => nil) do
        TurboDesktop.configure { |c| c.packaging_dir = paths[:packaging] }
        assert_equal paths[:packaging], TurboDesktop::Packaging.packaging_dir.to_s
      end
    end
  end

  def test_a_checkout_beside_the_gem_is_found_without_configuration
    # The common case: somebody working in the turbo_desktop repository itself.
    with_env("TURBO_DESKTOP_PACKAGING" => nil, "TURBO_DESKTOP_APP" => nil) do
      expected = File.expand_path("../../packaging", __dir__)
      skip "no checkout at #{expected}" unless File.exist?(File.join(expected, "pack.sh"))
      assert_equal expected, TurboDesktop::Packaging.packaging_dir.to_s
    end
  end

  def test_missing_packaging_directory_says_where_it_looked_and_what_to_do
    Dir.mktmpdir do |tmp|
      with_env("TURBO_DESKTOP_PACKAGING" => File.join(tmp, "nope"),
               "TURBO_DESKTOP_APP" => tmp) do
        TurboDesktop::Packaging.stub(:packaging_candidates, [ File.join(tmp, "nope") ]) do
          error = assert_raises(TurboDesktop::Packaging::MissingPrerequisite) do
            TurboDesktop::Packaging.packaging_dir
          end
          assert_match(/nope/, error.message, "must name the directories it tried")
          assert_match(/TURBO_DESKTOP_PACKAGING=/, error.message, "must say how to fix it")
          assert_match(/config\.packaging_dir/, error.message)
        end
      end
    end
  end

  def test_an_incomplete_packaging_directory_names_the_missing_script
    with_sandbox do |paths|
      FileUtils.rm(File.join(paths[:packaging], "build-runtime.sh"))
      error = assert_raises(TurboDesktop::Packaging::MissingPrerequisite) do
        TurboDesktop::Packaging.script("build-runtime.sh")
      end
      assert_match(/build-runtime\.sh/, error.message)
    end
  end
end

class PackagingRuntimeTest < Minitest::Test
  include PackagingSandbox

  def test_recognises_a_runtime_by_its_interpreter
    with_sandbox do |paths|
      assert TurboDesktop::Packaging.runtime?(paths[:runtime])
      assert_equal paths[:runtime], TurboDesktop::Packaging.runtime_dir
    end
  end

  def test_a_directory_without_bin_ruby_is_not_a_runtime
    with_sandbox(runtime: false) do |paths|
      FileUtils.mkdir_p(File.join(paths[:runtime], "bin"))
      refute TurboDesktop::Packaging.runtime?(paths[:runtime])
    end
  end

  def test_missing_runtime_explains_both_ways_to_get_one
    with_sandbox(runtime: false) do
      error = assert_raises(TurboDesktop::Packaging::MissingPrerequisite) do
        TurboDesktop::Packaging.runtime_dir!
      end
      assert_match(/desktop:runtime/, error.message)
      assert_match(/turbo_desktop-runtime/, error.message)
    end
  end

  def test_unix_builds_the_runtime_and_windows_fetches_one
    with_sandbox do |paths|
      on_platform(:macos) do
        argv = TurboDesktop::Packaging.runtime_command(out: "/tmp/out")
        assert_equal File.join(paths[:packaging], "build-runtime.sh"), argv.first
        assert_equal "/tmp/out", flag(argv, "--out")
      end

      on_platform(:windows) do
        argv = TurboDesktop::Packaging.runtime_command(out: "/tmp/out")
        # RubyInstaller already publishes a portable archive; building on
        # Windows would be work for its own sake.
        assert_includes argv.join(" "), "fetch-windows-runtime.ps1"
        assert_equal "/tmp/out", flag(argv, "-Out")
      end
    end
  end

  def test_the_build_directory_is_not_rails_tmp
    # `rails tmp:clear` would otherwise delete an interpreter that took twenty
    # minutes to compile.
    with_sandbox do |paths|
      with_env("TURBO_DESKTOP_BUILD" => nil) do
        refute_includes TurboDesktop::Packaging.build_dir.to_s, "#{File::SEPARATOR}tmp"
        assert_equal File.join(paths[:app], ".turbo-desktop"),
                     TurboDesktop::Packaging.build_dir.to_s
      end
    end
  end
end

class PackagingCommandTest < Minitest::Test
  include PackagingSandbox

  def test_macos_calls_pack_sh_with_a_bundle_id
    with_sandbox(gems: true, shell: true) do |paths|
      TurboDesktop.configure { |c| c.app_name = "Ledger"; c.app_id = "dev.example.ledger" }
      on_platform(:macos) do
        argv = TurboDesktop::Packaging.package_command

        assert_equal File.join(paths[:packaging], "pack.sh"), argv.first
        assert_equal paths[:app], flag(argv, "--app")
        assert_equal paths[:runtime], flag(argv, "--runtime")
        assert_equal paths[:gems], flag(argv, "--gems")
        assert_equal paths[:shell], flag(argv, "--shell")
        assert_equal "Ledger", flag(argv, "--name")
        assert_equal "dev.example.ledger", flag(argv, "--bundle-id")
        assert_equal paths[:dist], flag(argv, "--out")
      end
    end
  end

  def test_linux_calls_pack_linux_with_app_id_not_bundle_id
    with_sandbox(gems: true) do |paths|
      TurboDesktop.configure { |c| c.app_name = "Ledger"; c.app_id = "dev.example.ledger" }
      on_platform(:linux) do
        argv = TurboDesktop::Packaging.package_command

        assert_equal File.join(paths[:packaging], "pack-linux.sh"), argv.first
        assert_equal "dev.example.ledger", flag(argv, "--app-id")
        refute_includes argv, "--bundle-id", "pack-linux.sh has no --bundle-id"
        refute_includes argv, "--shell", "pack-linux.sh has no --shell"
      end
    end
  end

  def test_windows_calls_the_powershell_packer_through_pwsh
    with_sandbox do |paths|
      TurboDesktop.configure { |c| c.app_name = "Ledger"; c.app_id = "dev.example.ledger" }
      on_platform(:windows) do
        argv = TurboDesktop::Packaging.package_command

        assert_equal "pwsh", argv.first
        assert_equal "-File", argv[1]
        assert_equal File.join(paths[:packaging], "pack-windows.ps1"), argv[2]
        assert_equal "Ledger", flag(argv, "-Name")
        assert_equal "dev.example.ledger", flag(argv, "-AppId")
      end
    end
  end

  def test_optional_inputs_are_omitted_rather_than_passed_as_missing_paths
    # The packers skip a --gems directory that is not there without saying so,
    # which would hide the mistake until the bundle failed to boot on somebody
    # else's machine.
    with_sandbox(gems: false, shell: false) do
      on_platform(:macos) do
        argv = TurboDesktop::Packaging.package_command
        refute_includes argv, "--gems"
        refute_includes argv, "--shell"
      end
    end
  end

  def test_a_signing_identity_is_passed_only_when_configured
    with_sandbox do
      on_platform(:macos) do
        refute_includes TurboDesktop::Packaging.package_command, "--identity"

        TurboDesktop.configure { |c| c.signing_identity = "Developer ID Application: Ada" }
        argv = TurboDesktop::Packaging.package_command
        assert_equal "Developer ID Application: Ada", flag(argv, "--identity")
      end
    end
  end

  def test_an_app_without_config_ru_is_refused_with_a_reason
    Dir.mktmpdir do |tmp|
      with_env("TURBO_DESKTOP_APP" => tmp) do
        error = assert_raises(TurboDesktop::Packaging::MissingPrerequisite) do
          TurboDesktop::Packaging.app_root!
        end
        assert_match(/config\.ru/, error.message)
        assert_match(/TURBO_DESKTOP_APP=/, error.message)
      end
    end
  end

  def test_argv_is_a_list_so_a_path_with_a_space_cannot_split
    # "~/Library/Application Support" is on every Mac. Building a string and
    # letting a shell re-split it is how that becomes two arguments.
    with_sandbox do
      on_platform(:macos) do
        TurboDesktop.configure { |c| c.app_name = "My Ledger" }
        argv = TurboDesktop::Packaging.package_command
        assert_equal "My Ledger", flag(argv, "--name")
        assert_includes TurboDesktop::Packaging.to_shell(argv), "My\\ Ledger"
      end
    end
  end
end

class PackagingBootScriptTest < Minitest::Test
  include PackagingSandbox

  def test_finds_the_generated_boot_script
    with_sandbox do |paths|
      File.write(File.join(paths[:app], "bin", "desktop-boot"), "#!/usr/bin/env ruby\n")
      assert_equal File.join(paths[:app], "bin", "desktop-boot"),
                   TurboDesktop::Packaging.boot_script.to_s
    end
  end

  def test_falls_back_to_the_boot_rb_a_packer_copied_to_the_root
    with_sandbox do |paths|
      File.write(File.join(paths[:app], "boot.rb"), "")
      assert_equal File.join(paths[:app], "boot.rb"), TurboDesktop::Packaging.boot_script.to_s
    end
  end

  def test_missing_boot_script_points_at_the_generator
    with_sandbox do
      error = assert_raises(TurboDesktop::Packaging::MissingPrerequisite) do
        TurboDesktop::Packaging.boot_script
      end
      assert_match(/turbo_desktop:install/, error.message)
    end
  end
end

class PackagingHandshakeTest < Minitest::Test
  include PackagingSandbox

  def setup
    super
    TurboDesktop::Native.channel = nil
  end

  def teardown
    TurboDesktop::Native.channel = nil
    super
  end

  # The engine reads exactly one line from stdin while the app boots, and that
  # read blocks. A parent that holds stdin open — which it must, because closing
  # it is how the app is told to exit — but never writes will deadlock the child
  # before Puma binds: the app waits for a line that never comes, and the parent
  # waits for a port that is never announced. Measured: without this line the
  # generated bin/desktop-boot produced no output at all and had to be killed.
  def test_the_no_shell_handshake_is_one_line
    line = TurboDesktop::Packaging.no_shell_handshake
    refute_includes line, "\n", "puts adds the newline; two lines would desynchronise the stream"
    assert JSON.parse(line), "the engine parses this, so it has to be JSON"
  end

  def test_the_engine_dismisses_it_without_opening_a_channel
    io = StringIO.new("#{TurboDesktop::Packaging.no_shell_handshake}\n")
    assert_nil TurboDesktop::Native.read_handshake!(io)
    refute TurboDesktop::Native.available?,
           "desktop:run offers no control channel, and must not appear to"
  end

  def test_it_consumes_exactly_one_line_and_leaves_the_rest
    # The parent keeps the pipe open afterwards so that closing it is the exit
    # signal. Consuming more than the handshake would eat that.
    io = StringIO.new("#{TurboDesktop::Packaging.no_shell_handshake}\nstill here\n")
    TurboDesktop::Native.read_handshake!(io)
    assert_equal "still here\n", io.read
  end

  def test_a_real_shell_handshake_still_opens_a_channel
    # The counterpart: proof the dismissal above is about this line's content
    # and not about read_handshake! having been broken.
    io = StringIO.new(JSON.generate(control: "http://127.0.0.1:9", token: "t") + "\n")
    refute_nil TurboDesktop::Native.read_handshake!(io)
    assert TurboDesktop::Native.available?
  end

  def test_desktop_run_writes_it_before_reading_the_reply
    # Order is the whole point: writing after the read is the same deadlock.
    source = File.read(File.expand_path("../lib/turbo_desktop/tasks/desktop.rake", __dir__))
    write = source.index("no_shell_handshake")
    read = source.index("stdout.gets")
    refute_nil write, "desktop:run must write a handshake"
    refute_nil read
    assert_operator write, :<, read, "the handshake must be written before stdout is read"
  end
end

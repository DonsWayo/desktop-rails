require_relative "test_helper"
require "desktop_rails/packaging"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "stringio"
require "json"

# A sandbox that looks like what the packaging workflow reads: a Rails app to
# package, a runtime, gems, a shell, and a checkout of desktop-rails that is not
# the one the suite runs in. Building them here rather than pointing at the real
# repository keeps the assertions about *decisions* — which inputs, which
# layout — and not about whichever files happen to exist on the machine running
# the suite, such as a shell someone built with cargo.
module PackagingSandbox
  def with_sandbox(runtime: true, gems: false, shell: false, env: {})
    Dir.mktmpdir do |tmp|
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
      if gems
        # Shaped like a real gem set, not an empty directory: packaging refuses
        # an empty one, because it ships exactly as broken as a missing one.
        FileUtils.mkdir_p(File.join(gems_dir, "gems", "rack-3.2.7"))
        FileUtils.mkdir_p(File.join(gems_dir, "specifications"))
      end

      shell_bin = File.join(tmp, "desktop-rails")
      if shell
        File.write(shell_bin, "")
        FileUtils.chmod(0o755, shell_bin)
      end

      base = {
        "DESKTOP_RAILS_APP" => app,
        "DESKTOP_RAILS_RUNTIME" => (runtime ? runtime_dir : nil),
        "DESKTOP_RAILS_GEMS" => (gems ? gems_dir : nil),
        "DESKTOP_RAILS_SHELL" => (shell ? shell_bin : nil),
        "DESKTOP_RAILS_DIST" => File.join(tmp, "dist"),
        "DESKTOP_RAILS_BUILD" => File.join(tmp, "build")
      }.merge(env)

      with_env(base) do
        # A checkout exactly when the sandbox has a src-tauri/Cargo.toml, as
        # the real method decides.
        checkout = -> { File.file?(File.join(tmp, "src-tauri", "Cargo.toml")) ? Pathname.new(tmp) : nil }
        DesktopRails::Packaging.stub(:checkout_root, checkout) do
          yield({ root: tmp, app: app, runtime: runtime_dir,
                  gems: gems_dir, shell: shell_bin, dist: File.join(tmp, "dist") })
        end
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
    DesktopRails::Packaging.stub(:platform, platform, &block)
  end

  def flag(argv, name)
    index = argv.index(name)
    index && argv[index + 1]
  end
end

class PackagingCheckoutTest < Minitest::Test
  # Packaging needs nothing from a checkout any more; the only thing looked
  # for in one is a shell built from source. The suite runs in a checkout, so
  # it finds this one, and nothing named packaging/ is involved.
  def test_the_checkout_is_the_repository_the_gem_sits_in
    root = DesktopRails::Packaging.checkout_root
    skip "not in a checkout" unless root
    assert_equal File.expand_path("../..", __dir__), root.to_s
    assert File.file?(root.join("src-tauri", "Cargo.toml"))
  end

  def test_nothing_the_gem_packages_with_lives_outside_it
    gem_root = File.expand_path("..", __dir__)
    require "desktop_rails/bundled_package"
    require "desktop_rails/tooling/updater"
    [
      DesktopRails::BundledPackage::BOOT_TEMPLATE,
      DesktopRails::Packager::MacApp::ENTITLEMENTS,
      DesktopRails::Tooling::Updater::CLI_SCRIPT,
      *%w[launch-macos.sh.erb launch-linux.sh.erb launch-windows.cmd.erb].map do |name|
        File.expand_path("lib/desktop_rails/packager/templates/#{name}", gem_root)
      end
    ].each do |path|
      assert File.file?(path), "#{path} is missing"
      assert path.start_with?("#{gem_root}/lib/"), "#{path} is not under the gem's lib/, so the gem would not ship it"
    end
    refute DesktopRails::Packaging.respond_to?(:packaging_dir), "nothing looks for packaging scripts any more"
    refute DesktopRails.configuration.respond_to?(:packaging_dir)
  end
end

class PackagingRuntimeTest < Minitest::Test
  include PackagingSandbox

  def test_recognises_a_runtime_by_its_interpreter
    with_sandbox do |paths|
      assert DesktopRails::Packaging.runtime?(paths[:runtime])
      assert_equal paths[:runtime], DesktopRails::Packaging.runtime_dir
    end
  end

  def test_a_directory_without_bin_ruby_is_not_a_runtime
    with_sandbox(runtime: false) do |paths|
      FileUtils.mkdir_p(File.join(paths[:runtime], "bin"))
      refute DesktopRails::Packaging.runtime?(paths[:runtime])
    end
  end

  def test_missing_runtime_explains_both_ways_to_get_one
    with_sandbox(runtime: false) do
      error = assert_raises(DesktopRails::Packaging::MissingPrerequisite) do
        DesktopRails::Packaging.runtime_dir!
      end
      assert_match(/desktop:runtime/, error.message)
      assert_match(/DESKTOP_RAILS_RUNTIME=/, error.message)
      # The gem it used to suggest was never published, and never will be:
      # suggesting it sent people to a 404.
      refute_match(/bundle add/, error.message)
    end
  end

  def test_unix_builds_the_runtime_and_windows_fetches_one
    tool = File.expand_path("../exe/desktop-rails-tool", __dir__)
    with_sandbox do |paths|
      on_platform(:macos) do
        argv = DesktopRails::Packaging.runtime_command(out: "/tmp/out")
        # The gem's own tool, run by this Ruby: nothing outside the gem is
        # needed to build an interpreter any more.
        assert_equal [ RbConfig.ruby, tool, "runtime", "build" ], argv.first(4)
        assert_equal "/tmp/out", flag(argv, "--out")
        # Never the app directory, which packaging copies into the bundle.
        assert_equal File.join(paths[:root], "build", "runtime-build"), flag(argv, "--work")
      end

      on_platform(:windows) do
        argv = DesktopRails::Packaging.runtime_command(out: "/tmp/out")
        # RubyInstaller already publishes a portable archive; building on
        # Windows would be work for its own sake.
        assert_equal [ RbConfig.ruby, tool, "runtime", "fetch-windows" ], argv.first(4)
        assert_equal "/tmp/out", flag(argv, "--out")
      end
    end
  end

  def test_the_runtime_needs_no_packaging_scripts
    # The whole point of moving the tooling into the gem: an installed gem with
    # no checkout anywhere can still build and check an interpreter.
    DesktopRails::Packaging.stub(:checkout_root, nil) do
      assert File.exist?(DesktopRails::Packaging.runtime_command(out: "/tmp/out")[1])
      assert File.exist?(DesktopRails::Packaging.runtime_check_command("/tmp/out")[1])
    end
  end

  def test_a_runtime_is_built_where_desktop_rails_runtime_points
    # The variable is where a runtime is looked for first. Building somewhere
    # else meant a cache restored to that path was never filled on a miss, and
    # every later run built the interpreter again.
    with_sandbox(runtime: false) do |paths|
      target = File.join(paths[:root], "shared-runtime")
      with_env("DESKTOP_RAILS_RUNTIME" => target) do
        on_platform(:linux) do
          assert_equal target, flag(DesktopRails::Packaging.runtime_command, "--out")
        end
      end
      with_env("DESKTOP_RAILS_RUNTIME" => nil) do
        assert_equal File.join(paths[:root], "build", "runtime"),
                     DesktopRails::Packaging.runtime_build_dir.to_s
      end
    end
  end

  def test_gems_are_installed_by_the_shipped_interpreter_running_bundler
    # bin/bundle is a script with no extension. Windows cannot execute it, and
    # on Unix its shebang names the path the interpreter was built at.
    with_sandbox do |paths|
      env, *argv = DesktopRails::Packaging.gems_command
      assert_equal File.join(paths[:runtime], "bin", "ruby"), argv[0]
      assert_equal File.join(paths[:runtime], "bin", "bundle"), argv[1]
      assert_equal "install", argv[2]
      assert_equal "development:test", env["BUNDLE_WITHOUT"]

      File.write(File.join(paths[:runtime], "bin", "ruby.exe"), "")
      assert_equal File.join(paths[:runtime], "bin", "ruby.exe"),
                   DesktopRails::Packaging.gems_command[1]
    end
  end

  def test_the_build_directory_is_not_rails_tmp
    # `rails tmp:clear` would otherwise delete an interpreter that took twenty
    # minutes to compile.
    with_sandbox do |paths|
      with_env("DESKTOP_RAILS_BUILD" => nil) do
        # Compare against the app's own tmp, not the substring "/tmp". On Linux
        # the sandbox itself lives under /tmp, so the looser check failed there
        # while passing on macOS, where mktmpdir returns /var/folders.
        build_dir = DesktopRails::Packaging.build_dir.to_s
        rails_tmp = File.join(paths[:app], "tmp")

        refute build_dir.start_with?(rails_tmp),
               "#{build_dir} is inside #{rails_tmp}, which `rails tmp:clear` deletes"
        assert_equal File.join(paths[:app], ".desktop-rails"), build_dir
      end
    end
  end
end

class PackagingCommandTest < Minitest::Test
  include PackagingSandbox

  def test_the_package_takes_every_input_the_workflow_resolved
    with_sandbox(gems: true, shell: true) do |paths|
      DesktopRails.configure { |c| c.app_name = "Ledger"; c.app_id = "dev.example.ledger" }
      on_platform(:macos) do
        package = DesktopRails::Packaging.bundled_package

        assert_equal paths[:app], package.app
        assert_equal paths[:runtime], package.runtime.dir
        assert_equal paths[:gems], package.gems
        assert_equal paths[:shell], package.shell
        assert_equal "Ledger", package.name
        assert_equal "dev.example.ledger", package.app_id
        assert_equal paths[:dist], package.out.to_s
        assert_equal :macos, package.platform
        assert_instance_of DesktopRails::Packager::MacApp, package.layout
      end
    end
  end

  def test_each_platform_gets_its_own_layout_and_embeds_the_shell
    # Leaving the shell out on Linux and Windows is how every package there
    # once came out with no window even when a shell was sitting right there.
    with_sandbox(gems: true, shell: true) do |paths|
      { linux: DesktopRails::Packager::LinuxTree, windows: DesktopRails::Packager::WindowsTree }.each do |platform, layout|
        on_platform(platform) do
          package = DesktopRails::Packaging.bundled_package
          assert_instance_of layout, package.layout
          assert_equal paths[:shell], package.shell
        end
      end
    end
  end

  def test_a_missing_shell_is_omitted_rather_than_passed_as_a_missing_path
    # A bundle with no window is a legitimate thing to build — it is how the
    # packaging itself is tested — so the shell stays optional.
    with_sandbox(gems: true, shell: false) do
      on_platform(:macos) do
        assert_nil DesktopRails::Packaging.bundled_package.shell
      end
    end
  end

  def test_packaging_refuses_a_bundle_with_no_gems
    # Gems are not optional. This used to omit --gems silently, and a real app
    # packaged that way reported success and "signature verifies" over a bundle
    # that died on `require "rack"`. Refusing here is the whole fix.
    with_sandbox(gems: false, shell: false) do
      on_platform(:macos) do
        error = assert_raises(DesktopRails::Packaging::MissingPrerequisite) do
          DesktopRails::Packaging.bundled_package
        end
        assert_match(/No gems to package/, error.message)
        assert_match(/desktop:gems/, error.message)
      end
    end
  end

  def test_a_signing_identity_comes_from_the_initializer
    with_sandbox(gems: true) do
      on_platform(:macos) do
        assert_equal "-", DesktopRails::Packaging.bundled_package.layout.identity

        DesktopRails.configure { |c| c.signing_identity = "Developer ID Application: Ada" }
        assert_equal "Developer ID Application: Ada", DesktopRails::Packaging.bundled_package.layout.identity
      end
    end
  end

  def test_an_app_without_config_ru_is_refused_with_a_reason
    Dir.mktmpdir do |tmp|
      with_env("DESKTOP_RAILS_APP" => tmp) do
        error = assert_raises(DesktopRails::Packaging::MissingPrerequisite) do
          DesktopRails::Packaging.app_root!
        end
        assert_match(/config\.ru/, error.message)
        assert_match(/DESKTOP_RAILS_APP=/, error.message)
      end
    end
  end

  def test_desktop_package_builds_in_ruby_and_runs_no_packer_script
    source = File.read(File.expand_path("../lib/desktop_rails/tasks/desktop.rake", __dir__))
    package_task = source[/task package: .*?\n  end\n/m]
    assert_includes package_task, "bundled_package"
    assert_includes package_task, ".build"
    refute_match(/pack\.sh|pack-linux|pack-windows|pwsh|run\.call/, package_task)
    # fresh-app.yml checks which shell was packaged from this line.
    assert_includes package_task, %(puts "  shell:   )
  end
end

class PackagingBootScriptTest < Minitest::Test
  include PackagingSandbox

  def test_finds_the_generated_boot_script
    with_sandbox do |paths|
      File.write(File.join(paths[:app], "bin", "desktop-boot"), "#!/usr/bin/env ruby\n")
      assert_equal File.join(paths[:app], "bin", "desktop-boot"),
                   DesktopRails::Packaging.boot_script.to_s
    end
  end

  def test_falls_back_to_the_boot_rb_a_packer_copied_to_the_root
    with_sandbox do |paths|
      File.write(File.join(paths[:app], "boot.rb"), "")
      assert_equal File.join(paths[:app], "boot.rb"), DesktopRails::Packaging.boot_script.to_s
    end
  end

  def test_missing_boot_script_points_at_the_generator
    with_sandbox do
      error = assert_raises(DesktopRails::Packaging::MissingPrerequisite) do
        DesktopRails::Packaging.boot_script
      end
      assert_match(/desktop_rails:install/, error.message)
    end
  end
end

class PackagingHandshakeTest < Minitest::Test
  include PackagingSandbox

  def setup
    super
    DesktopRails::Native.channel = nil
  end

  def teardown
    DesktopRails::Native.channel = nil
    super
  end

  # The engine reads exactly one line from stdin while the app boots, and that
  # read blocks. A parent that holds stdin open — which it must, because closing
  # it is how the app is told to exit — but never writes will deadlock the child
  # before Puma binds: the app waits for a line that never comes, and the parent
  # waits for a port that is never announced. Measured: without this line the
  # generated bin/desktop-boot produced no output at all and had to be killed.
  def test_the_no_shell_handshake_is_one_line
    line = DesktopRails::Packaging.no_shell_handshake
    refute_includes line, "\n", "puts adds the newline; two lines would desynchronise the stream"
    assert JSON.parse(line), "the engine parses this, so it has to be JSON"
  end

  def test_the_engine_dismisses_it_without_opening_a_channel
    io = StringIO.new("#{DesktopRails::Packaging.no_shell_handshake}\n")
    assert_nil DesktopRails::Native.read_handshake!(io, env: { "DESKTOP_RAILS_HANDSHAKE" => "stdin" })
    refute DesktopRails::Native.available?,
           "desktop:run offers no control channel, and must not appear to"
  end

  def test_it_consumes_exactly_one_line_and_leaves_the_rest
    # The parent keeps the pipe open afterwards so that closing it is the exit
    # signal. Consuming more than the handshake would eat that.
    io = StringIO.new("#{DesktopRails::Packaging.no_shell_handshake}\nstill here\n")
    DesktopRails::Native.read_handshake!(io, env: { "DESKTOP_RAILS_HANDSHAKE" => "stdin" })
    assert_equal "still here\n", io.read
  end

  def test_a_real_shell_handshake_still_opens_a_channel
    # The counterpart: proof the dismissal above is about this line's content
    # and not about read_handshake! having been broken.
    io = StringIO.new(JSON.generate(control: "http://127.0.0.1:9", token: "t") + "\n")
    refute_nil DesktopRails::Native.read_handshake!(io, env: { "DESKTOP_RAILS_HANDSHAKE" => "stdin" })
    assert DesktopRails::Native.available?
  end

  def test_desktop_run_writes_it_before_reading_the_reply
    # Order is the whole point: writing after the read is the same deadlock.
    source = File.read(File.expand_path("../lib/desktop_rails/tasks/desktop.rake", __dir__))
    write = source.index("no_shell_handshake")
    read = source.index("stdout.gets")
    refute_nil write, "desktop:run must write a handshake"
    refute_nil read
    assert_operator write, :<, read, "the handshake must be written before stdout is read"
  end
end

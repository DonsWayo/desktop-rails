require_relative "tooling_test_helper"
require "desktop_rails/tooling/runtime_verification"

class ToolingRuntimeVerificationTest < Minitest::Test
  include WithoutBundlerInChildren
  include ToolingTestSupport

  Verification = DesktopRails::Tooling::RuntimeVerification

  OTOOL_HOMEBREW = <<~OUT
    /Users/me/.rubies/3.4.8/lib/ruby/3.4.0/arm64-darwin25/openssl.bundle:
    	/Users/me/.rubies/3.4.8/lib/libruby.3.4.dylib (compatibility version 3.4.0, current version 3.4.8)
    	/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib (compatibility version 3.0.0, current version 3.0.0)
    	/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib (compatibility version 3.0.0, current version 3.0.0)
    	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
  OUT

  OTOOL_CLEAN = <<~OUT
    /tmp/relocated/ruby/bin/ruby:
    	/usr/lib/libz.1.dylib (compatibility version 1.0.0, current version 1.2.12)
    	/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
  OUT

  LDD_LINUXBREW = <<~OUT
    	linux-vdso.so.1 (0x00007ffd)
    	libssl.so.3 => /home/linuxbrew/.linuxbrew/lib/libssl.so.3 (0x00007f)
    	libz.so.1 => /lib/x86_64-linux-gnu/libz.so.1 (0x00007f)
    	libyaml-0.so.2 => /usr/local/lib/libyaml-0.so.2 (0x00007f)
  OUT

  def test_a_homebrew_openssl_is_named_on_macos
    links = Verification.package_manager_links(OTOOL_HOMEBREW, :macos)
    assert_equal 2, links.size
    assert(links.all? { |line| line.start_with?("/opt/homebrew/opt/openssl@3") })
    assert_empty Verification.package_manager_links(OTOOL_CLEAN, :macos)
  end

  def test_linuxbrew_and_a_hand_installed_library_are_named_on_linux
    links = Verification.package_manager_links(LDD_LINUXBREW, :linux)
    assert_equal 2, links.size
    assert_match(/linuxbrew/, links[0])
    assert_match(%r{/usr/local/lib/libyaml}, links[1])
  end

  def test_linkage_is_read_with_the_platforms_own_tool
    assert_equal [ "otool", "-L", "/x" ], Verification.new("/r", host_os: "darwin24").linkage_argv("/x")
    assert_equal [ "ldd", "/x" ], Verification.new("/r", host_os: "linux-gnu").linkage_argv("/x")
    # A Windows interpreter resolves its DLLs beside itself; there is no
    # package-manager prefix to find.
    assert_nil Verification.new("C:/r", host_os: "mingw32").linkage_argv("C:/x")
  end

  def test_the_openssl_probe_output_is_split_into_built_and_loaded
    assert_equal [ "OpenSSL 3.5.4 30 Sep 2025", "OpenSSL 3.0.13 30 Jan 2024" ],
                 Verification.parse_openssl("OpenSSL 3.5.4 30 Sep 2025 | runtime OpenSSL 3.0.13 30 Jan 2024")
    assert_nil Verification.parse_openssl("-e:2:in 'require': cannot load such file -- openssl")
    assert_nil Verification.parse_openssl("")
  end

  def test_binaries_are_extensions_libraries_and_the_interpreter_but_not_links
    Dir.mktmpdir do |dir|
      executable(File.join(dir, "bin", "ruby"))
      write(File.join(dir, "lib", "libruby.dylib"))
      write(File.join(dir, "lib", "ruby", "3.4.0", "arm64-darwin", "openssl.bundle"))
      write(File.join(dir, "lib", "ruby", "3.4.0", "x86_64-linux", "psych.so"))
      write(File.join(dir, "lib", "ruby", "3.4.0", "psych.rb"))
      File.symlink(File.join(dir, "bin", "ruby"), File.join(dir, "bin", "ruby3.4"))
      File.symlink("libruby.dylib", File.join(dir, "lib", "libruby.3.4.dylib"))

      found = Verification.binaries_in(dir).map { |path| path.delete_prefix("#{dir}/") }
      assert_equal %w[bin/ruby lib/libruby.dylib lib/ruby/3.4.0/arm64-darwin/openssl.bundle
                      lib/ruby/3.4.0/x86_64-linux/psych.so], found
    end
  end

  def test_the_probes_pass_on_the_ruby_running_this_suite
    # They are Ruby source in strings; running them proves they parse and that
    # a working interpreter passes them, so a typo cannot fail every runtime.
    command = DesktopRails::Tooling::Command.new(out: StringIO.new)
    assert command.capture([ RbConfig.ruby, "-e", Verification::PSYCH_PROBE ], clean_ruby: true).success?
    assert command.capture([ RbConfig.ruby, "-e", Verification::CORE_EXTENSIONS_PROBE ], clean_ruby: true).success?

    openssl = command.capture([ RbConfig.ruby, "-e", Verification::OPENSSL_PROBE ], clean_ruby: true)
    assert openssl.success?, openssl.output
    refute_nil Verification.parse_openssl(openssl.output)

    relocated = command.capture([ RbConfig.ruby, "-e", Verification::RELOCATION_PROBE ],
                                env: { "DESKTOP_RAILS_RELOCATED_RUBY" => RbConfig.ruby }, clean_ruby: true)
    assert relocated.success?, "RbConfig of this Ruby should describe this Ruby"

    elsewhere = command.capture([ RbConfig.ruby, "-e", Verification::RELOCATION_PROBE ],
                                env: { "DESKTOP_RAILS_RELOCATED_RUBY" => "/nonexistent/bin/ruby" }, clean_ruby: true)
    refute elsewhere.success?, "a prefix pointing somewhere else must fail"
  end

  def test_a_healthy_runtime_passes_every_check_from_a_copy
    with_runtime do |runtime|
      runner = healthy_runner
      log = StringIO.new
      assert Verification.new(runtime, host_os: "darwin24", runner: runner, log: log).verify

      # Every question is asked of the moved copy, never of the original.
      ruby_calls = runner.argvs.select { |argv| argv.first.end_with?("bin/ruby") }
      refute_empty ruby_calls
      assert(ruby_calls.all? { |argv| argv.first.include?("/relocated/ruby/bin/ruby") && !argv.first.start_with?(runtime) })
      assert(runner.calls.select { |argv, _| argv.first.end_with?("bin/ruby") }.all? { |_, o| o[:clean_ruby] })
      assert_includes log.string, "PASS"
      assert_includes log.string, "built and runtime OpenSSL agree"
      refute Dir.exist?(File.dirname(File.dirname(ruby_calls.first.first))), "the copy is cleaned up"
    end
  end

  def test_a_mismatched_openssl_fails_even_though_the_probe_ran
    with_runtime do |runtime|
      runner = healthy_runner(openssl: "OpenSSL 3.5.4 30 Sep 2025 | runtime OpenSSL 3.0.13 30 Jan 2024")
      log = StringIO.new
      refute Verification.new(runtime, host_os: "darwin24", runner: runner, log: log).verify
      assert_includes log.string, "built against OpenSSL 3.5.4 30 Sep 2025 but loading OpenSSL 3.0.13 30 Jan 2024"
      assert_includes log.string, "FAIL"
    end
  end

  def test_package_manager_linkage_fails_and_says_which_binary
    with_runtime do |runtime|
      runner = healthy_runner
      runner.on(->(argv) { argv.first == "otool" && argv.last.end_with?("openssl.bundle") }, output: OTOOL_HOMEBREW)
      log = StringIO.new
      refute Verification.new(runtime, host_os: "darwin24", runner: runner, log: log).verify
      assert_includes log.string, "package-manager linkage:"
      assert_includes log.string, "openssl.bundle: /opt/homebrew/opt/openssl@3/lib/libssl.3.dylib"
    end
  end

  def test_windows_asks_the_same_questions_of_ruby_exe_without_a_linkage_tool
    with_runtime(exe: "ruby.exe") do |runtime|
      runner = healthy_runner
      assert Verification.new(runtime, host_os: "mingw32", runner: runner, log: StringIO.new).verify
      refute(runner.argvs.any? { |argv| %w[otool ldd].include?(argv.first) })
      assert(runner.argvs.any? { |argv| argv.first.end_with?("bin/ruby.exe") && argv.include?(Verification::OPENSSL_PROBE) })
    end
  end

  def test_a_directory_without_an_interpreter_fails_without_copying
    Dir.mktmpdir do |dir|
      log = StringIO.new
      refute Verification.new(dir, host_os: "linux-gnu", runner: RecordingRunner.new, log: log).verify
      assert_includes log.string, "has no bin/ruby"
      assert_raises(DesktopRails::Tooling::CheckFailed) do
        Verification.new(dir, host_os: "linux-gnu", runner: RecordingRunner.new, log: StringIO.new).verify!
      end
    end
  end

  private

  def with_runtime(exe: "ruby")
    Dir.mktmpdir do |dir|
      runtime = File.join(dir, "ruby")
      executable(File.join(runtime, "bin", exe))
      write(File.join(runtime, "lib", "ruby", "3.4.0", "arm64-darwin", "openssl.bundle"))
      yield runtime
    end
  end

  def healthy_runner(openssl: "OpenSSL 3.5.4 30 Sep 2025 | runtime OpenSSL 3.5.4 30 Sep 2025")
    RecordingRunner.new.tap do |runner|
      runner.on(->(argv) { argv.include?(Verification::OPENSSL_PROBE) }, output: openssl)
      runner.on(->(argv) { argv.first == "otool" }, output: OTOOL_CLEAN)
    end
  end
end

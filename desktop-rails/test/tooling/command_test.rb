require_relative "tooling_test_helper"

# The runner every step shells out through. These run real processes — this
# Ruby, with -e — because what is being tested is how a process is started and
# how its failure is reported, and a fake would only restate the answer.
class ToolingCommandTest < Minitest::Test
  include WithoutBundlerInChildren
  Command = DesktopRails::Tooling::Command

  def setup
    super
    @out = StringIO.new
    @command = Command.new(out: @out)
  end

  def test_output_is_passed_through_as_it_arrives
    assert @command.run([ RbConfig.ruby, "-e", "puts 'one'; $stdout.flush; warn 'two'" ])
    assert_includes @out.string, "one\n"
    assert_includes @out.string, "two\n", "stderr belongs in the same stream, or a build's errors vanish"
  end

  def test_a_failure_names_the_command_its_status_and_where_it_ran
    Dir.mktmpdir do |dir|
      error = assert_raises(DesktopRails::Tooling::CommandFailed) do
        @command.run([ RbConfig.ruby, "-e", "exit 3", "with space" ], chdir: dir)
      end
      assert_match(/exit 3/, error.message)
      assert_includes error.message, "with\\ space", "the command must be pasteable, spaces and all"
      assert_includes error.message, "in #{dir}"
      assert_equal 3, error.status.exitstatus
    end
  end

  def test_quiet_keeps_output_off_screen_but_puts_its_end_in_the_failure
    # A build prints tens of thousands of lines. The ones that explain a failure
    # are the last few, and without them the only way to find out why is to run
    # the build again by hand.
    script = "$stdout.sync = true; 200.times { |i| puts \"line \#{i}\" }; warn 'the actual error'; exit 1"
    error = assert_raises(DesktopRails::Tooling::CommandFailed) do
      @command.run([ RbConfig.ruby, "-e", script ], quiet: true)
    end
    assert_empty @out.string
    assert_includes error.message, "the actual error"
    assert_includes error.message, "line 199"
    refute_includes error.message, "line 0\n", "only the tail, not the whole build"
  end

  def test_verbose_overrides_quiet
    command = Command.new(out: @out, verbose: true)
    command.run([ RbConfig.ruby, "-e", "puts 'shown'" ], quiet: true)
    assert_includes @out.string, "shown"
  end

  def test_a_program_that_is_not_there_says_so
    error = assert_raises(DesktopRails::Tooling::CommandFailed) do
      @command.run([ "desktop-rails-no-such-program" ])
    end
    assert_match(/Could not run desktop-rails-no-such-program/, error.message)
    assert_match(/on PATH/, error.message)
  end

  def test_capture_returns_failure_as_an_answer
    result = @command.capture([ RbConfig.ruby, "-e", "print 'out'; exit 2" ])
    refute result.success?
    assert_equal "out", result.output
  end

  def test_capture_bang_returns_output_or_raises
    assert_equal "ok", @command.capture!([ RbConfig.ruby, "-e", "print 'ok'" ])
    assert_raises(DesktopRails::Tooling::CommandFailed) { @command.capture!([ RbConfig.ruby, "-e", "exit 1" ]) }
  end

  def test_clean_ruby_keeps_bundler_away_from_the_child
    # bin/rails and `bundle exec` export RUBYOPT=-rbundler/setup. An
    # interpreter under test that inherits it tries to load this app's bundle
    # and fails for a reason that has nothing to do with the interpreter.
    probe = [ RbConfig.ruby, "-e", "print [ENV['RUBYOPT'], ENV['BUNDLE_GEMFILE'], ENV['KEPT']].inspect" ]
    with_parent_env("RUBYOPT" => "-rbundler/setup", "BUNDLE_GEMFILE" => "/elsewhere/Gemfile",
                    "BUNDLER_SETUP" => "/elsewhere/bundler/setup") do
      assert_equal '[nil, nil, "yes"]', @command.capture!(probe, env: { "KEPT" => "yes" }, clean_ruby: true)
      # Without the flag the child really would inherit it, which is the
      # failure this exists to prevent.
      refute @command.capture(probe).success?
    end
  end

  def test_an_explicit_nil_unsets_a_variable
    with_parent_env("PKG_CONFIG_PATH" => "/opt/homebrew/lib/pkgconfig") do
      output = @command.capture!([ RbConfig.ruby, "-e", "print ENV['PKG_CONFIG_PATH'].inspect" ],
                                 env: { "PKG_CONFIG_PATH" => nil })
      assert_equal "nil", output
    end
  end

  def test_it_is_the_runner_package_layouts_call
    # One way to start a program: the layouts' runner contract is argv in,
    # success out, and a failure either of them raises is one class.
    require "desktop_rails/packager"
    assert_instance_of Command, DesktopRails::Packager.system_runner
    assert_same DesktopRails::Tooling::CommandFailed, DesktopRails::Packager::CommandFailed

    assert_equal true, @command.call([ RbConfig.ruby, "-e", "puts 'signed'" ])
    assert_includes @out.string, "signed"
    assert_equal false, @command.call([ RbConfig.ruby, "-e", "exit 1" ])
    assert_equal false, @command.call([ "desktop-rails-no-such-program" ])
    assert_match(/Could not run desktop-rails-no-such-program/, @out.string)
  end

  def test_invalid_utf8_output_is_not_an_encoding_error
    error = assert_raises(DesktopRails::Tooling::CommandFailed) do
      @command.run([ RbConfig.ruby, "-e", "$stdout.write(\"\\xff\\xfe bad bytes\\n\"); exit 1" ], quiet: true)
    end
    assert_includes error.message, "bad bytes"
  end

  private

  def with_parent_env(values)
    previous = values.keys.to_h { |k| [ k, ENV[k] ] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end

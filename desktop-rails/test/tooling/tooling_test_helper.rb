require_relative "../test_helper"
require "desktop_rails/tooling/command"
require "fileutils"
require "stringio"
require "tmpdir"

# A process runner that runs nothing. It records every argv it is handed and
# answers from a list of rules, so a test can say "otool reports this" or
# "the probe fails" and then assert on what the step decided.
class RecordingRunner
  Status = Struct.new(:success?, :exitstatus, :termsig)

  attr_reader :calls

  def initialize
    @calls = []
    @rules = []
  end

  # The most recently added rule whose matcher accepts argv decides the result,
  # so a test can start from a healthy runner and override one answer. A
  # matcher is a proc over argv.
  def on(matcher, output: "", success: true, &effect)
    @rules << [ matcher, output, success, effect ]
    self
  end

  def run(argv, **options)
    output, ok = answer(argv, options)
    raise DesktopRails::Tooling::CommandFailed.new("#{argv.first} failed:\n#{output}", argv: argv) unless ok

    true
  end

  def capture(argv, **options)
    output, ok = answer(argv, options)
    DesktopRails::Tooling::Command::Result.new(output: output, status: Status.new(ok, ok ? 0 : 1, nil))
  end

  def capture!(argv, **options)
    output, ok = answer(argv, options)
    raise DesktopRails::Tooling::CommandFailed.new("#{argv.first} failed:\n#{output}", argv: argv) unless ok

    output
  end

  def argvs
    calls.map(&:first)
  end

  private

  def answer(argv, options)
    argv = argv.map(&:to_s)
    @calls << [ argv, options ]
    matcher, output, success, effect = @rules.reverse.find { |rule| rule.first.call(argv) }
    return [ "", true ] unless matcher

    effect&.call(argv, options)
    [ output, success ]
  end
end

# For tests that start real Ruby processes. The suite runs under `bundle
# exec`, so every child would otherwise inherit RUBYOPT=-rbundler/setup and
# resolve this Gemfile before running one line — seconds per process on a busy
# machine — and a child that should be testing its own environment would be
# testing Bundler's.
module WithoutBundlerInChildren
  def before_setup
    super
    @bundler_environment = DesktopRails::Tooling::Command::RUBY_ENVIRONMENT.to_h { |name| [ name, ENV.delete(name) ] }
  end

  def after_teardown
    @bundler_environment&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    super
  end
end

module ToolingTestSupport
  def write(path, content = "")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  def executable(path, content = "#!/bin/sh\n")
    write(path, content)
    FileUtils.chmod(0o755, path)
    path
  end
end

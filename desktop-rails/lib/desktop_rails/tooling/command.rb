# frozen_string_literal: true

require "open3"
require "shellwords"
require "desktop_rails/tooling"

module DesktopRails
  module Tooling
    # A subprocess that failed, with enough in the message to act on: the
    # command as it could be pasted into a terminal, its exit status, where it
    # ran, and the last of its output when that was not already on screen.
    class CommandFailed < Error
      attr_reader :argv, :status, :output

      def initialize(message, argv: nil, status: nil, output: nil)
        super(message)
        @argv = argv
        @status = status
        @output = output
      end
    end

    # Runs the programs every step is made of — configure, make, codesign,
    # hdiutil, node — and nothing else about them.
    #
    # Always argv, never a string for a shell to split: "Application Support" is
    # on every Mac, and a path with a space in it must reach the program as one
    # argument.
    #
    # Output is read line by line as it is produced rather than collected at the
    # end, so a forty-minute OpenSSL build shows progress, or at least is not
    # silent. `quiet: true` keeps a build's thousands of compiler lines off the
    # screen but still holds on to the last of them, because "make failed (exit
    # 2)" on its own sends someone to rerun the build by hand to find out why.
    class Command
      TAIL_LINES = 60

      # Variables with which a Ruby process sets itself up. A step running
      # under `bundle exec` or bin/rails inherits RUBYOPT=-rbundler/setup and
      # friends, and any Ruby started from there — the interpreter being built
      # or checked, above all — would then try to load this bundle with the
      # wrong interpreter and fail with an error that names neither.
      RUBY_ENVIRONMENT = %w[
        RUBYOPT RUBYLIB GEM_HOME GEM_PATH
        BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLE_PATH BUNDLE_WITHOUT
        BUNDLER_SETUP BUNDLER_VERSION
      ].freeze

      Result = Struct.new(:output, :status, keyword_init: true) do
        def success?
          status&.success? || false
        end
      end

      attr_reader :out

      def initialize(out: $stdout, verbose: false)
        @out = out
        @verbose = verbose
      end

      def verbose?
        @verbose
      end

      # Runs argv to completion and raises CommandFailed unless it succeeded.
      def run(argv, env: {}, chdir: nil, quiet: false, clean_ruby: false)
        quiet = false if verbose?
        tail = []
        status = stream(argv, env: env, chdir: chdir, clean_ruby: clean_ruby) do |line|
          if quiet
            tail << line
            tail.shift while tail.size > TAIL_LINES
          else
            out.print(line)
          end
        end
        return true if status.success?

        raise CommandFailed.new(failure_message(argv, status, chdir: chdir, tail: quiet ? tail : nil),
                                argv: argv, status: status, output: tail.join)
      end

      # The runner contract DesktopRails::Packager's layouts take — argv in,
      # whether it succeeded out — so packaging and the build-machine tooling
      # start programs one way. Output passes through, and a program that could
      # not be started is a false with its reason printed, as `system` would
      # answer nil.
      #
      # `quiet: true` holds the output back and prints it only if the program
      # failed, for commands whose success is chatter: codesign says "replacing
      # existing signature" once for each of a bundle's hundred-odd binaries.
      def call(argv, quiet: false)
        held = []
        status = stream(argv, env: {}, chdir: nil, clean_ruby: true) do |line|
          quiet ? held << line : out.print(line)
        end
        out.print(held.last(TAIL_LINES).join) if quiet && !status.success?
        status.success?
      rescue CommandFailed => e
        out.puts(e.message)
        false
      end

      # Runs argv and returns its combined output and status whatever happened,
      # for the commands whose failure is an answer rather than an error:
      # `strip` on a file it cannot strip, `ldd` on something that is not
      # dynamic, a probe that is expected to fail on a broken runtime.
      def capture(argv, env: {}, chdir: nil, clean_ruby: false)
        output = +""
        status = stream(argv, env: env, chdir: chdir, clean_ruby: clean_ruby) { |line| output << line }
        Result.new(output: output, status: status)
      end

      # The output of a command that has to succeed.
      def capture!(argv, env: {}, chdir: nil, clean_ruby: false)
        result = capture(argv, env: env, chdir: chdir, clean_ruby: clean_ruby)
        return result.output if result.success?

        raise CommandFailed.new(failure_message(argv, result.status, chdir: chdir, tail: result.output.lines.last(TAIL_LINES)),
                                argv: argv, status: result.status, output: result.output)
      end

      def self.to_shell(argv)
        argv.map { |arg| Shellwords.escape(arg.to_s) }.join(" ")
      end

      def self.environment(env, clean_ruby: false)
        base = clean_ruby ? RUBY_ENVIRONMENT.to_h { |name| [ name, nil ] } : {}
        base.merge(env.transform_keys(&:to_s).transform_values { |v| v&.to_s })
      end

      private

      def stream(argv, env:, chdir:, clean_ruby:, &block)
        argv = argv.map(&:to_s)
        options = {}
        options[:chdir] = chdir.to_s if chdir
        environment = self.class.environment(env, clean_ruby: clean_ruby)
        spawn = lambda do
          Open3.popen2e(environment, *argv, options) do |stdin, output, wait|
            stdin.close
            # Compiler output is not always valid UTF-8, and an invalid byte
            # must not turn a build failure into an encoding error.
            output.each_line { |line| block.call(line.dup.force_encoding(Encoding::UTF_8).scrub) }
            wait.value
          end
        end
        # Under `bundle exec` or bin/rails, Bundler also rewrites variables the
        # list above does not name; its own unbundled environment undoes them.
        clean_ruby && defined?(Bundler) ? Bundler.with_unbundled_env(&spawn) : spawn.call
      rescue SystemCallError => e
        # ENOENT, EACCES: the program never started, which deserves its own
        # sentence rather than a Ruby backtrace from inside Open3.
        raise CommandFailed.new("Could not run #{argv.first}: #{e.message}. " \
                                "Is it installed and on PATH?", argv: argv)
      end

      def failure_message(argv, status, chdir:, tail:)
        code = status.exitstatus ? "exit #{status.exitstatus}" : "killed by signal #{status.termsig}"
        message = +"#{File.basename(argv.first.to_s)} failed (#{code}):\n  #{self.class.to_shell(argv)}"
        message << "\n  in #{chdir}" if chdir
        if tail && !tail.empty?
          message << "\n\nLast lines of its output:\n"
          message << tail.join.gsub(/^/, "    ")
        end
        message
      end
    end
  end
end

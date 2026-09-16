# frozen_string_literal: true

require "optparse"
require "desktop_rails/packaging"
require "desktop_rails/tooling"

module DesktopRails
  module Tooling
    # The command line over the tooling classes: exe/desktop-rails-tool.
    #
    # Thin on purpose. Each subcommand parses its options into keyword
    # arguments and hands them to one class; anything worth testing lives in
    # that class. Every subcommand exits non-zero with a sentence, not a
    # backtrace, when something it needs is missing or a check fails.
    class CLI
      USAGE = <<~TEXT
        usage: desktop-rails-tool <command> [options]

          runtime build [--out DIR] [--work DIR]    build a relocatable Ruby (macOS, Linux)
          runtime verify DIR                         prove an interpreter relocates
          runtime fetch-windows --out DIR            RubyInstaller's portable Ruby, checked
          prune DIR [--keep-dev]                     remove what a user's machine never reads
          dmg APP [OUTPUT]                           wrap a .app in a disk image
          notarize --app APP --identity ID           sign, notarise and staple a .app
          updater generate-key [--name N]            the minisign keypair that signs updates
          updater sign --artifact F --version V --url U
                                                     sign an update and write its manifest
          smoke launch LAUNCHER                      a packaged app's server holds its contract
          smoke shell SHELL                          the GUI shell starts, serves and reaps
          smoke app SHELL [CHECKS...]                the window loaded the app (DESKTOP_DATA_DIR)

        Run any command with --help for its options.
      TEXT

      def self.start(argv, out: $stdout, err: $stderr, env: ENV)
        new(out: out, err: err, env: env).run(argv.dup)
      end

      def initialize(out:, err:, env:)
        @out = out
        @err = err
        @env = env
      end

      def run(argv)
        command = argv.shift
        case command
        when "runtime" then runtime(argv)
        when "prune" then prune(argv)
        when "dmg" then dmg(argv)
        when "notarize" then notarize(argv)
        when "updater" then updater(argv)
        when "smoke" then smoke(argv)
        when nil, "-h", "--help", "help"
          @out.puts USAGE
          command.nil? ? 2 : 0
        else
          usage_error("unknown command: #{command}")
        end
      rescue OptionParser::ParseError => e
        usage_error(e.message)
      rescue Error => e
        @err.puts "\n#{e.message}"
        1
      rescue DesktopRails::Packaging::DownloadFailed, DesktopRails::Packaging::NotPublished => e
        @err.puts "\n#{e.message}"
        1
      end

      private

      def usage_error(message)
        @err.puts message
        @err.puts USAGE
        2
      end

      def runner(verbose: false)
        Command.new(out: @out, verbose: verbose)
      end

      def parse(argv, banner)
        options = {}
        parser = OptionParser.new do |opts|
          opts.banner = "usage: desktop-rails-tool #{banner}"
          yield opts, options
        end
        rest = parser.parse(argv)
        [ options, rest, parser ]
      end

      def runtime(argv)
        case (sub = argv.shift)
        when "build"
          require "desktop_rails/tooling/runtime_build"
          options, = parse(argv, "runtime build [options]") do |opts, o|
            opts.on("--out DIR", "Where the interpreter goes (default: WORK/out/ruby)") { |v| o[:out] = v }
            opts.on("--work DIR", "Sources and vendored libraries (default: ./.runtime-build)") { |v| o[:work] = v }
            # Flags rather than the RUBY_VERSION the shell script read: rvm
            # exports RUBY_VERSION=ruby-3.3.0 into every shell it manages.
            opts.on("--ruby VERSION", "Ruby to build (default: #{RuntimeBuild::DEFAULT_RUBY_VERSION})") { |v| o[:ruby_version] = v }
            opts.on("--openssl VERSION", "OpenSSL (default: #{RuntimeBuild::DEFAULT_OPENSSL_VERSION})") { |v| o[:openssl_version] = v }
            opts.on("--yaml VERSION", "libyaml (default: #{RuntimeBuild::DEFAULT_YAML_VERSION})") { |v| o[:yaml_version] = v }
            opts.on("--verbose", "Show compiler output as it happens") { o[:verbose] = true }
          end
          verbose = options.delete(:verbose)
          RuntimeBuild.new(**options, runner: runner(verbose: verbose), log: @out).build!
          0
        when "verify"
          require "desktop_rails/tooling/runtime_verification"
          _, rest, parser = parse(argv, "runtime verify DIR") { nil }
          return usage_error(parser.help) unless rest.size == 1

          RuntimeVerification.new(rest.first, runner: runner, log: @out).verify ? 0 : 1
        when "fetch-windows"
          require "desktop_rails/tooling/windows_runtime"
          options, = parse(argv, "runtime fetch-windows --out DIR [--version V]") do |opts, o|
            opts.on("--out DIR", "Where the interpreter goes") { |v| o[:out] = v }
            opts.on("--version VERSION", "RubyInstaller version (default: #{WindowsRuntime::DEFAULT_VERSION})") { |v| o[:version] = v }
          end
          return usage_error("runtime fetch-windows needs --out") unless options[:out]

          WindowsRuntime.new(out: options[:out], version: options[:version], runner: runner, log: @out).fetch!
          0
        else
          usage_error("unknown runtime command: #{sub.inspect}")
        end
      end

      def prune(argv)
        require "desktop_rails/tooling/prune"
        options, rest, parser = parse(argv, "prune DIR [--keep-dev]") do |opts, o|
          opts.on("--keep-dev", "Keep documentation and gem test suites (also KEEP_DEV=1)") { o[:keep_dev] = true }
        end
        return usage_error(parser.help) unless rest.size == 1

        keep_dev = options[:keep_dev] || @env["KEEP_DEV"] == "1"
        Prune.new(rest.first, keep_dev: keep_dev, runner: runner, log: @out).run!
        0
      end

      def dmg(argv)
        require "desktop_rails/tooling/disk_image"
        _, rest, parser = parse(argv, "dmg APP [OUTPUT]") { nil }
        return usage_error(parser.help) unless [ 1, 2 ].include?(rest.size)

        DiskImage.new(rest[0], output: rest[1], runner: runner, log: @out).create!
        0
      end

      def notarize(argv)
        require "desktop_rails/tooling/notarization"
        options, = parse(argv, "notarize --app APP --identity ID [options]") do |opts, o|
          opts.on("--app APP", "The signed .app") { |v| o[:app] = v }
          opts.on("--identity ID", "\"Developer ID Application: Name (TEAMID)\"") { |v| o[:identity] = v }
          opts.on("--keychain-profile NAME", "notarytool credentials (default: notary)") { |v| o[:keychain_profile] = v }
          opts.on("--entitlements FILE", "Entitlements for the interpreter") { |v| o[:entitlements] = v }
        end
        return usage_error("notarize needs --app") unless options[:app]

        Notarization.new(**options, runner: runner, log: @out).notarize!
        0
      end

      def updater(argv)
        require "desktop_rails/tooling/updater"
        case (sub = argv.shift)
        when "generate-key"
          options, = parse(argv, "updater generate-key [--name NAME] [--dir DIR] [--force]") do |opts, o|
            opts.on("--name NAME", "Key file name (default: updater)") { |v| o[:name] = v }
            opts.on("--dir DIR", "Where the keys go (default: ./.signing)") { |v| o[:dir] = v }
            opts.on("--force", "Overwrite an existing key") { o[:force] = true }
          end
          Updater::KeyGeneration.new(**options, env: @env, runner: runner, log: @out).generate!
          0
        when "sign"
          options, = parse(argv, "updater sign --artifact FILE --version V --url URL [options]") do |opts, o|
            opts.on("--artifact FILE", "The bundle the updater installs") { |v| o[:artifact] = v }
            opts.on("--version VERSION", "Semver, for the whole release") { |v| o[:version] = v }
            opts.on("--target TARGET", "<darwin|linux|windows>-<arch> (default: this machine)") { |v| o[:target] = v }
            opts.on("--url URL", "Where the artifact will be downloaded from") { |v| o[:url] = v }
            opts.on("--key FILE", "Secret key (default: .signing/updater.key, or $DESKTOP_RAILS_SIGNING_KEY)") { |v| o[:key] = v }
            opts.on("--public FILE", "Public key to verify against (default: beside --key)") { |v| o[:public_key] = v }
            opts.on("--manifest FILE", "Manifest to merge into (default: latest.json beside the artifact)") { |v| o[:manifest] = v }
            opts.on("--sig FILE", "Signature output (default: ARTIFACT.sig)") { |v| o[:sig] = v }
            opts.on("--notes TEXT", "Release notes") { |v| o[:notes] = v }
            opts.on("--notes-file FILE", "Release notes from a file") { |v| o[:notes_file] = v }
            opts.on("--pub-date RFC3339", "Publication date (default: now)") { |v| o[:pub_date] = v }
          end
          Updater::Signing.new(artifact: options.delete(:artifact), version: options.delete(:version),
                               url: options.delete(:url), **options, env: @env, runner: runner, log: @out).sign!
          0
        else
          usage_error("unknown updater command: #{sub.inspect}")
        end
      end

      def smoke(argv)
        require "desktop_rails/tooling/smoke"
        case (sub = argv.shift)
        when "launch"
          return usage_error("usage: desktop-rails-tool smoke launch LAUNCHER") unless argv.size == 1

          Smoke::LaunchCheck.new(argv.first, out: @out).run
        when "shell"
          return usage_error("usage: desktop-rails-tool smoke shell SHELL") unless argv.size == 1

          Smoke::ShellCheck.new(argv.first, deadline: integer(@env["SHELL_CHECK_TIMEOUT"], 240), out: @out).run
        when "app"
          return usage_error("usage: DESKTOP_DATA_DIR=DIR desktop-rails-tool smoke app SHELL [CHECKS...]") if argv.empty?

          binary, *checks = argv
          Smoke::AppCheck.new(binary, checks, data_dir: @env["DESKTOP_DATA_DIR"],
                                              deadline: integer(@env["APP_CHECK_TIMEOUT"], 240), out: @out).run
        else
          usage_error("unknown smoke command: #{sub.inspect}")
        end
      end

      def integer(value, default)
        Integer(Paths.presence(value) || default)
      end
    end
  end
end

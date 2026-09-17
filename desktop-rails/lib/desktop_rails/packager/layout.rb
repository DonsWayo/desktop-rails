# frozen_string_literal: true

require "erb"
require "fileutils"
require "pathname"

module DesktopRails
  module Packager
    # What every platform's package has in common: a directory under `out`
    # named after the app, an executable somewhere in it, a config the shell
    # will find, maybe an icon, and a last step that makes it something to hand
    # out. Subclasses say where each of those goes.
    #
    # A bundled package, DesktopRails::BundledPackage, also puts an
    # interpreter, the app's gems and the app in `bundle_dir`, and a launcher
    # that starts the app with them at `launcher_path`. A hosted package uses
    # neither.
    class Layout
      attr_reader :out, :name, :app_id, :version, :executable_name, :runner, :log

      def initialize(out:, name:, app_id:, executable_name:, version: "1.0",
                     runner: Packager.system_runner, log: ->(message) { puts message })
        @out = Pathname.new(out.to_s)
        @name = name.to_s
        @app_id = app_id.to_s
        @version = version.to_s
        @executable_name = executable_name.to_s
        @runner = runner
        @log = log
        raise ArgumentError, "A package needs a name" if @name.strip.empty?
        raise ArgumentError, "A package needs an app id" if @app_id.strip.empty?
      end

      def slug
        Packager.slug(name)
      end

      # The directory this layout owns and replaces on every build.
      def root
        raise NotImplementedError
      end

      def executable_path
        raise NotImplementedError
      end

      # Where the shell reads its desktop-rails.config.json from.
      def config_path
        raise NotImplementedError
      end

      # Where a bundled package's ruby/, gems/ and app/ go.
      def bundle_dir
        raise NotImplementedError
      end

      # The script that sets up the environment and runs the bundled
      # interpreter: what the shell spawns, and what runs the server with no
      # shell at all.
      def launcher_path
        raise NotImplementedError
      end

      # The launcher as server.command in the config, relative to the
      # directory the config is in, which is how the shell resolves it.
      def launcher_command
        raise NotImplementedError
      end

      def launcher_template
        raise NotImplementedError
      end

      # The launcher rendered from its template in the gem, with the only two
      # things that vary: the app id, which names the data directory, and the
      # interpreter's ABI directory, which holds its default gems.
      def launcher(app_id:, abi:)
        template = File.read(File.expand_path("templates/#{launcher_template}", __dir__))
        ERB.new(template).result_with_hash(app_id: app_id, abi: abi)
      end

      def write_launcher(abi:)
        FileUtils.mkdir_p(File.dirname(launcher_path))
        File.binwrite(launcher_path, launcher_newlines(launcher(app_id: app_id, abi: abi)))
        FileUtils.chmod(0o755, launcher_path)
        self
      end

      # Files a person is handed, besides the directory itself.
      def artifacts
        []
      end

      # Start from nothing, so a file left by an earlier build cannot ship.
      def prepare!
        FileUtils.rm_rf(root)
        FileUtils.mkdir_p(root)
        self
      end

      def install_executable(source)
        FileUtils.mkdir_p(File.dirname(executable_path))
        FileUtils.cp(source.to_s, executable_path)
        FileUtils.chmod(0o755, executable_path)
        self
      end

      def write_config(json)
        FileUtils.mkdir_p(File.dirname(config_path))
        File.write(config_path, json)
        self
      end

      # Nil when the platform has nowhere to put an icon after the executable
      # is built; the caller says so rather than failing the package.
      def install_icon(_source)
        nil
      end

      def finish!
        self
      end

      private

      def launcher_newlines(text)
        text
      end

      # The runner, asked to keep a successful command's output to itself when
      # it is the tooling's Command. Any other callable, such as a test's, is
      # called with argv alone, which is the whole runner contract.
      def call_quietly(argv)
        runner.is_a?(Tooling::Command) ? runner.call(argv, quiet: true) : runner.call(argv)
      end

      def run!(argv, quiet: false)
        return if quiet ? call_quietly(argv) : runner.call(argv)

        raise CommandFailed, "#{argv.first} failed: #{argv.map(&:to_s).join(" ")}"
      end
    end
  end
end

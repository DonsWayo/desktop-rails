# frozen_string_literal: true

require "fileutils"
require "pathname"

module DesktopRails
  module Packager
    # What every platform's package has in common: a directory under `out`
    # named after the app, an executable somewhere in it, a config the shell
    # will find, maybe an icon, and a last step that makes it something to hand
    # out. Subclasses say where each of those goes.
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

      def run!(argv)
        return if runner.call(argv)

        raise CommandFailed, "#{argv.first} failed: #{argv.map(&:to_s).join(" ")}"
      end
    end
  end
end

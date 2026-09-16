# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "desktop_rails/tooling/command"
require "desktop_rails/tooling/runtime_verification"

module DesktopRails
  module Tooling
    # Fetches RubyInstaller's portable archive and checks it relocates.
    #
    # Windows is fetched rather than built. RubyInstaller already ships a
    # portable interpreter that resolves relative to itself, so building a second
    # one would be work for its own sake. Spike 3 established that it relocates,
    # tolerates a path containing a space, and boots Rails with no compiler
    # present.
    #
    # Two things still use this now that releases carry a prebuilt Windows
    # runtime: the release workflow, which is what produces that prebuilt one,
    # and desktop:runtime on a Windows machine the release does not serve or
    # that asked for DESKTOP_RAILS_RUNTIME_FROM_SOURCE.
    class WindowsRuntime
      # The same Ruby the macOS and Linux runtimes are built from.
      DEFAULT_VERSION = "4.0.7"

      attr_reader :version, :out

      def initialize(out:, version: nil, runner: Command.new, fetcher: nil, log: $stdout, verification: nil)
        @out = File.expand_path(out.to_s)
        @version = version || DEFAULT_VERSION
        @runner = runner
        @fetcher = fetcher
        @log = log
        @verification = verification
      end

      def url
        "https://github.com/oneclick/rubyinstaller2/releases/download/" \
          "RubyInstaller-#{version}-1/rubyinstaller-#{version}-1-x64.7z"
      end

      def extract_argv(archive, into)
        [ "7z", "x", archive.to_s, "-o#{into}", "-y" ]
      end

      # The archive holds one top-level directory, named after the release.
      def self.unpacked_root(dir)
        entries = Dir.children(dir).map { |name| File.join(dir, name) }.select { |path| File.directory?(path) }
        raise CheckFailed, "#{dir} holds no interpreter directory after unpacking" if entries.empty?

        entries.min
      end

      def fetch!
        @log.puts "Fetching #{url}"
        # Downloaded and unpacked in a scratch directory of its own.
        # desktop:runtime runs this from the application root, where a ruby.7z
        # left behind would be packaged into the app, and a fixed C:\unpacked
        # collides with the previous run.
        Dir.mktmpdir("desktop-rails-runtime-") do |scratch|
          archive = File.join(scratch, "ruby.7z")
          fetcher.call(url, archive)
          unpacked = File.join(scratch, "unpacked")
          @runner.run(extract_argv(archive, unpacked), quiet: true)

          FileUtils.mkdir_p(File.dirname(out))
          FileUtils.rm_rf(out)
          FileUtils.cp_r(self.class.unpacked_root(unpacked), out)
        end

        (@verification || RuntimeVerification.new(out, runner: @runner, log: @log)).verify!
        out
      end

      private

      def fetcher
        @fetcher ||= begin
          require "desktop_rails/prebuilt"
          Prebuilt::HttpFetcher.new
        end
      end
    end
  end
end

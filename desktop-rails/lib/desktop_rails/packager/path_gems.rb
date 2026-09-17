# frozen_string_literal: true

require "fileutils"
require "pathname"
require "desktop_rails/packager"
require "desktop_rails/packager/tree_copy"

module DesktopRails
  module Packager
    # Copies an app's path gems into the package and points its Gemfile at the
    # copies.
    #
    # A Gemfile's `path:` is relative to where the app was developed. Inside a
    # packaged app it points at nothing and the app dies at boot with
    # Bundler::PathError. Path gems are ordinary — local engines, monorepo gems,
    # this gem itself while it is used from GitHub or a checkout — so this is
    # not a corner case.
    #
    # It rewrites the COPY of the app inside the package, never the developer's
    # own Gemfile. Each path source named in Gemfile.lock is copied into
    # vendor/path-gems/<name>, and both Gemfile.lock and Gemfile are pointed
    # there.
    class PathGems
      VENDOR = "vendor/path-gems"

      # What a gem needs at runtime, without its history, build output or
      # tests. Only at the gem's own top level, as before: a lib/foo/test/
      # directory is library code.
      SKIPPED = %w[/.git /tmp /log /node_modules /test /spec].freeze

      def initialize(original:, packed:, log: ->(message) { puts message })
        @original = Pathname.new(File.expand_path(original.to_s))
        @packed = Pathname.new(File.expand_path(packed.to_s))
        @log = log
      end

      # The remotes vendored, as { remote => relative path in the package }.
      def vendor!
        lockfile = @packed.join("Gemfile.lock")
        gemfile = @packed.join("Gemfile")
        return {} unless lockfile.exist?

        lock = lockfile.read
        remotes = lock.scan(/^PATH\r?\n  remote: (.+?)\r?$/).flatten.uniq
        if remotes.empty?
          @log.call("  no path gems")
          return {}
        end

        vendored = remotes.to_h do |remote|
          source = source_for(remote)
          name = source.basename.to_s
          destination = @packed.join(VENDOR, name)
          FileUtils.rm_rf(destination)
          TreeCopy.copy(source, destination, excludes: SKIPPED)

          relative = "#{VENDOR}/#{name}"
          lock = lock.gsub(/^(PATH\r?\n  remote: )#{Regexp.escape(remote)}(\r?)$/) { "#{$1}#{relative}#{$2}" }

          text = gemfile.read
          # Any quoting, and either the `path:` or the `:path =>` spelling.
          rewritten = text.gsub(/(path:\s*|:path\s*=>\s*)(["'])#{Regexp.escape(remote)}\2/) do
            "#{$1}#{$2}#{relative}#{$2}"
          end
          if rewritten == text
            raise InvalidInput, "#{remote} is in Gemfile.lock but not found as a path: in the Gemfile; not guessing."
          end
          gemfile.write(rewritten)

          @log.call("  vendored #{name} from #{remote}")
          [ remote, relative ]
        end

        lockfile.write(lock)
        vendored
      end

      private

      # Resolved against the ORIGINAL app, which is where a relative path meant
      # something.
      def source_for(remote)
        path = Pathname.new(remote)
        source = (path.absolute? ? path : @original.join(remote)).expand_path
        unless source.directory?
          raise InvalidInput, "The path gem #{remote} resolves to #{source}, which does not exist."
        end

        source
      end
    end
  end
end

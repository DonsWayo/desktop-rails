# frozen_string_literal: true

require "fileutils"
require "find"

module DesktopRails
  module Packager
    # Copies a directory tree into a package, the way `rsync -a` with exclude
    # patterns did in the shell packers, with one implementation on every
    # platform.
    #
    # Symbolic links are copied as links, not followed: a relocatable
    # interpreter carries relative ones (libruby.dylib naming the versioned
    # library), and following them would ship the same library twice, or a
    # link to a directory would pull in a tree from outside the package.
    # File permissions and modification times are kept, because a copied
    # bin/ruby that lost its executable bit does not start. Directory modes are
    # not: a read-only directory in the source would stop the package being
    # vendored into, pruned, or deleted by the next build.
    #
    # Excludes are rsync's own two kinds, so the rules read the same as before:
    # "tmp/" is a directory of that name at any depth, and "/storage/" or
    # "/config/master.key" is anchored at the top of the tree. A trailing slash
    # matches directories only, and "*" never crosses a "/".
    class TreeCopy
      attr_reader :source, :destination, :excludes

      def self.copy(source, destination, excludes: [])
        new(source, destination, excludes: excludes).copy
      end

      def initialize(source, destination, excludes: [])
        @source = File.expand_path(source.to_s)
        @destination = File.expand_path(destination.to_s)
        @excludes = excludes.map { |pattern| Pattern.new(pattern) }
      end

      def excluded?(relative, directory:)
        excludes.any? { |pattern| pattern.match?(relative, directory: directory) }
      end

      def copy
        FileUtils.mkdir_p(destination)
        Find.find(source) do |path|
          next if path == source

          relative = path.delete_prefix("#{source}/")
          stat = File.lstat(path)
          if excluded?(relative, directory: stat.directory?)
            Find.prune if stat.directory?
            next
          end

          target = File.join(destination, relative)
          if stat.symlink?
            File.symlink(File.readlink(path), target)
          elsif stat.directory?
            FileUtils.mkdir_p(target)
          elsif stat.file?
            FileUtils.copy_file(path, target)
            File.chmod(stat.mode & 0o7777, target)
            File.utime(stat.atime, stat.mtime, target)
          end
        end
        destination
      end

      # One rsync-style exclude.
      class Pattern
        def initialize(pattern)
          pattern = pattern.to_s
          @directory_only = pattern.end_with?("/")
          @anchored = pattern.start_with?("/")
          body = pattern.delete_prefix("/").delete_suffix("/")
          @regexp = Regexp.new("\\A#{body.split("*", -1).map { |part| Regexp.escape(part) }.join("[^/]*")}\\z")
        end

        def match?(relative, directory:)
          return false if @directory_only && !directory

          if @anchored
            @regexp.match?(relative)
          else
            # Unanchored, a pattern with no slash names an entry at any depth.
            @regexp.match?(File.basename(relative))
          end
        end
      end
    end
  end
end

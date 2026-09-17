# frozen_string_literal: true

require "desktop_rails/packager"

module DesktopRails
  module Packager
    # Stops the Windows interpreter in a packaged app writing into its own tree.
    #
    # RubyInstaller's rubygems/defaults/operating_system.rb runs every time
    # RubyGems loads, so on every launch of the app. Its first act is to create
    # and delete a file called writable_p in Gem.default_dir, which is inside
    # the package, to decide whether `gem install` should default to a per-user
    # directory. The Windows GUI job found it: nothing else a packaged app does
    # touches the tree, and this did so on each start.
    #
    # A packaged app never installs a gem, so the answer does not matter, but
    # the write does: an app installed under C:\Program Files cannot write
    # there, and a tree that behaves differently depending on where it was
    # unpacked is harder to reason about than one that does not. So the probe is
    # replaced by the answer a read-only install gets, EACCES, and every copy of
    # the app takes the same branch. The rest of the file — the DLL search paths
    # especially — is left exactly as RubyInstaller wrote it.
    #
    # This rewrites the COPY of the interpreter inside the package, never the
    # runtime it was copied from.
    module WindowsGemProbe
      PROBE = %r{
        ^(?<indent>[ \t]*)checkfile\s*=\s*File\.join\(Gem\.default_dir,\s*"/writable_p"\)[ \t]*\r?\n
        [ \t]*File\.write\(checkfile,\s*""\)[ \t]*\r?\n
        [ \t]*File\.unlink\(checkfile\)[^\r\n]*\r?\n
      }x

      REPLACEMENT = <<~RUBY
        # desktop-rails: a packaged app never writes into its own interpreter, so
        # it takes the branch a read-only install takes instead of probing with a
        # file. See DesktopRails::Packager::WindowsGemProbe.
        raise Errno::EACCES, "a packaged app's interpreter is read-only"
      RUBY

      module_function

      # The file's new source, or nil when there is nothing to change. Raises
      # when the file still probes in a way this does not recognise, so a new
      # RubyInstaller release is noticed at packaging time rather than as a
      # write inside every installed app.
      def rewrite(source)
        return nil unless source.include?("writable_p")

        match = PROBE.match(source)
        unless match
          raise InvalidInput, "RubyInstaller's operating_system.rb still mentions writable_p, but not in the shape " \
                              "desktop-rails knows how to disable. A new RubyInstaller release needs looking at."
        end

        newline = match[0].include?("\r\n") ? "\r\n" : "\n"
        replacement = REPLACEMENT.lines.map { |line| "#{match[:indent]}#{line.chomp}#{newline}" }.join
        source.sub(PROBE) { replacement }
      end

      # RubyInstaller installs it under lib/ruby/<ABI>; site_ruby is where
      # RubyGems would also find one. expand_path because a Windows path's
      # backslashes are escapes in a glob pattern, and the first version of
      # this found nothing and said so.
      def files(runtime)
        root = File.expand_path(runtime.to_s)
        Dir.glob(File.join(root, "lib", "ruby", "{site_ruby/*,*}", "rubygems", "defaults", "operating_system.rb")).uniq
      end

      def apply(runtime)
        files(runtime).filter_map do |file|
          rewritten = rewrite(File.binread(file))
          next unless rewritten

          File.binwrite(file, rewritten)
          file
        end
      end
    end
  end
end

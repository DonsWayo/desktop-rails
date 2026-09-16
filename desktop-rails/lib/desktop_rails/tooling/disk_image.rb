# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "desktop_rails/tooling/command"

module DesktopRails
  module Tooling
    # Wraps a .app in a disk image, which is how macOS apps are actually
    # delivered.
    #
    # No certificate needed to build one. Signing and notarising the *contents*
    # is a separate step, and what Gatekeeper judges on first launch.
    class DiskImage
      attr_reader :app

      def initialize(app, output: nil, runner: Command.new, log: $stdout)
        @app = File.expand_path(app.to_s)
        @output = output && File.expand_path(output.to_s)
        @runner = runner
        @log = log
      end

      def name
        File.basename(app, ".app")
      end

      def output
        @output || File.join(File.dirname(app), "#{name}.dmg")
      end

      # ditto rather than a Ruby copy. A signed launcher script keeps its
      # signature in extended attributes, which FileUtils does not copy, and an
      # image of a bundle whose seal is broken is an image of a bundle macOS
      # refuses to open.
      def copy_argv(stage)
        [ "ditto", app, File.join(stage, File.basename(app)) ]
      end

      def hdiutil_argv(stage)
        [ "hdiutil", "create", "-volname", name, "-srcfolder", stage, "-ov", "-format", "UDZO", "-quiet", output ]
      end

      def create!
        raise MissingPrerequisite, "#{app} is not a .app bundle" unless File.directory?(app) && app.end_with?(".app")

        Dir.mktmpdir("desktop-rails-dmg-") do |scratch|
          stage = File.join(scratch, name)
          FileUtils.mkdir_p(stage)
          @runner.run(copy_argv(stage))
          # The drag-to-install convention.
          File.symlink("/Applications", File.join(stage, "Applications"))

          FileUtils.rm_f(output)
          @runner.run(hdiutil_argv(stage))
        end

        @log.puts "#{output} (#{Tooling.human_size(File.size(output))})"
        output
      end
    end
  end
end

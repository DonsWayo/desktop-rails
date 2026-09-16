# frozen_string_literal: true

require "fileutils"
require "desktop_rails/packager/archive"
require "desktop_rails/packager/layout"

module DesktopRails
  module Packager
    # A Windows application directory, plus a zip of it.
    #
    # The executable is renamed after the app, which is what a person sees in
    # Explorer and the taskbar, and the config sits beside it, where Tauri's
    # resource directory resolves for a plain executable.
    class WindowsTree < Layout
      def root
        out.join(slug)
      end

      def executable_path
        root.join("#{slug}.exe")
      end

      def config_path
        root.join(CONFIG_FILENAME)
      end

      def archive_path
        out.join("#{slug}-windows-x64.zip")
      end

      def artifacts
        [ archive_path ]
      end

      # The icon of a Windows executable is a resource compiled into it, so a
      # prebuilt shell keeps its own. Nil tells the caller nothing was applied.
      def install_icon(_source)
        nil
      end

      def finish!
        Archive.zip(root, into: archive_path)
        log.call("  #{archive_path}")
        self
      end
    end
  end
end

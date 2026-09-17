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
    # resource directory resolves for a plain executable. A bundled package
    # adds lib/ with the interpreter, the gems and the app, and <slug>.cmd, the
    # launcher the executable spawns.
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

      def bundle_dir
        root.join("lib")
      end

      def launcher_path
        root.join("#{slug}.cmd")
      end

      def launcher_command
        "#{slug}.cmd"
      end

      def launcher_template
        "launch-windows.cmd.erb"
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

      private

      # CRLF, which is what cmd.exe is written for: it misreads parts of a
      # batch file with bare LF line endings, and a checkout's own line
      # endings must not decide that.
      def launcher_newlines(text)
        text.gsub(/\r?\n/, "\r\n")
      end
    end
  end
end

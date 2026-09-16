# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "desktop_rails/packager/archive"
require "desktop_rails/packager/layout"

module DesktopRails
  module Packager
    # A Linux application directory that runs from wherever it is unpacked,
    # plus a tarball of it.
    #
    # The config sits beside the executable. Tauri's resource directory does
    # not resolve there on Linux — it names /usr/lib/<ProductName> whether or
    # not anything was installed — so the shell looks beside its own binary as
    # well, and that is the one place a tree unpacked into /opt or a home
    # directory has.
    class LinuxTree < Layout
      def initialize(arch: RbConfig::CONFIG["host_cpu"], **options)
        super(**options)
        @arch = arch
      end

      def root
        out.join(slug)
      end

      def executable_path
        root.join(slug)
      end

      def config_path
        root.join(CONFIG_FILENAME)
      end

      def desktop_entry_path
        root.join("share", "applications", "#{app_id}.desktop")
      end

      def icon_path
        root.join("share", "icons", "hicolor", "512x512", "apps", "#{app_id}.png")
      end

      def archive_path
        out.join("#{slug}-linux-#{@arch}.tar.gz")
      end

      def artifacts
        [ archive_path ]
      end

      # Desktop icon themes take PNGs; there is no converting a .icns here.
      def install_icon(source)
        unless File.extname(source.to_s).casecmp?(".png")
          raise InvalidInput, "A Linux icon must be a .png, not #{File.basename(source.to_s)}"
        end

        FileUtils.mkdir_p(File.dirname(icon_path))
        FileUtils.cp(source.to_s, icon_path)
        icon_path
      end

      def desktop_entry
        lines = [
          "[Desktop Entry]",
          "Type=Application",
          "Name=#{name}",
          "Exec=#{slug}",
          "Icon=#{app_id}",
          "Categories=Office;",
          "Terminal=false"
        ]
        lines.join("\n") + "\n"
      end

      def finish!
        FileUtils.mkdir_p(File.dirname(desktop_entry_path))
        File.write(desktop_entry_path, desktop_entry)
        Archive.tar_gz(root, into: archive_path)
        log.call("  #{archive_path}")
        self
      end
    end
  end
end

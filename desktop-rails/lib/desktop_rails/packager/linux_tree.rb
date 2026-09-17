# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "desktop_rails/packager/archive"
require "desktop_rails/packager/layout"
require "desktop_rails/tooling"

module DesktopRails
  module Packager
    # A Linux application directory that runs from wherever it is unpacked,
    # plus a tarball of it.
    #
    # The config sits beside the executable. Tauri's resource directory does
    # not resolve there on Linux — it names /usr/lib/<ProductName> whether or
    # not anything was installed — so the shell looks beside its own binary as
    # well, and that is the one place a tree unpacked into /opt or a home
    # directory has. A bundled package adds lib/ with the interpreter, the
    # gems and the app, and bin/<slug>, the launcher the executable spawns.
    class LinuxTree < Layout
      # AppImage is built on top of the tarball when asked for and appimagetool
      # is on PATH, since that is the format many people expect to download.
      def initialize(arch: RbConfig::CONFIG["host_cpu"], appimage: false, **options)
        super(**options)
        @arch = arch
        @appimage = appimage
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

      def bundle_dir
        root.join("lib")
      end

      def launcher_path
        root.join("bin", slug)
      end

      def launcher_command
        "bin/#{slug}"
      end

      def launcher_template
        "launch-linux.sh.erb"
      end

      def appimage_dir
        out.join("#{slug}.AppDir")
      end

      def appimage_path
        out.join("#{name}-#{@arch}.AppImage")
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
        build_appimage if @appimage
        self
      end

      def appimage_command
        [ "appimagetool", appimage_dir.to_s, appimage_path.to_s ]
      end

      private

      # The tree as it is, with the desktop entry at the top and AppRun
      # pointing at the launcher, which is the layout appimagetool reads.
      def build_appimage
        unless Tooling.which("appimagetool")
          log.call("  appimagetool is not installed; skipping the AppImage (the tarball is self-contained)")
          return
        end

        FileUtils.rm_rf(appimage_dir)
        FileUtils.cp_r(root, appimage_dir, preserve: true)
        FileUtils.cp(desktop_entry_path, appimage_dir.join("#{app_id}.desktop"))
        File.symlink("bin/#{slug}", appimage_dir.join("AppRun"))
        run!(appimage_command)
        log.call("  #{appimage_path}")
      end
    end
  end
end

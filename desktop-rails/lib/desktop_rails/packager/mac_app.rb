# frozen_string_literal: true

require "cgi"
require "fileutils"
require "desktop_rails/packager/layout"

module DesktopRails
  module Packager
    # A macOS application bundle: <Name>.app, signed.
    #
    # The config goes in Contents/Resources, which is the shell's resource
    # directory on macOS and the only place a packaged shell reads it from.
    # Signing covers the executable first and the bundle last, the inside-out
    # order codesign needs, with the hardened runtime a notarized app must have.
    class MacApp < Layout
      ICON_FILE = "AppIcon"

      # "-" signs ad hoc, which is all a build that is not being distributed
      # needs, and what the bundled packer defaults to.
      def initialize(identity: "-", **options)
        super(**options)
        @identity = identity.to_s.strip.empty? ? "-" : identity.to_s
        @icon = false
      end

      attr_reader :identity

      def root
        out.join("#{name}.app")
      end

      def contents
        root.join("Contents")
      end

      def resources
        contents.join("Resources")
      end

      def executable_path
        contents.join("MacOS", executable_name)
      end

      def config_path
        resources.join(CONFIG_FILENAME)
      end

      # A .icns is copied; a .png is converted by sips, which every Mac has.
      def install_icon(source)
        FileUtils.mkdir_p(resources)
        target = resources.join("#{ICON_FILE}.icns")
        case File.extname(source.to_s).downcase
        when ".icns" then FileUtils.cp(source.to_s, target)
        when ".png" then run!([ "sips", "-s", "format", "icns", source.to_s, "--out", target.to_s ])
        else raise InvalidInput, "A macOS icon must be a .icns or a .png, not #{File.basename(source.to_s)}"
        end
        @icon = true
        target
      end

      def info_plist
        entries = {
          "CFBundleName" => name,
          "CFBundleDisplayName" => name,
          "CFBundleIdentifier" => app_id,
          "CFBundleExecutable" => executable_name,
          "CFBundlePackageType" => "APPL",
          "CFBundleShortVersionString" => version,
          "CFBundleVersion" => version,
          "LSMinimumSystemVersion" => "12.0",
          # macOS prompts per app bundle for these, whatever language asks.
          "NSDocumentsFolderUsageDescription" => "#{name} needs access to files you open.",
          "NSDownloadsFolderUsageDescription" => "#{name} needs access to files you open."
        }
        entries["CFBundleIconFile"] = ICON_FILE if @icon

        body = entries.map { |key, value| "  <key>#{key}</key><string>#{CGI.escapeHTML(value)}</string>" }
        body << "  <key>NSHighResolutionCapable</key><true/>"
        <<~PLIST
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
          #{body.join("\n")}
          </dict>
          </plist>
        PLIST
      end

      # Inside-out: the executable, then the bundle that seals it together
      # with Info.plist and the config. A config edited after this breaks the
      # seal, which is the point — see README "Where the config is read from".
      def signing_commands
        base = [ "codesign", "--force", "--timestamp=none", "--options", "runtime", "--sign", identity ]
        [ base + [ executable_path.to_s ], base + [ root.to_s ] ]
      end

      def verify_command
        [ "codesign", "--verify", "--strict", "--deep", root.to_s ]
      end

      def finish!
        File.write(contents.join("Info.plist"), info_plist)
        signing_commands.each { |argv| run!(argv) }
        run!(verify_command)
        log.call("  signed (#{identity == "-" ? "ad hoc" : identity}) and verified")
        self
      end
    end
  end
end

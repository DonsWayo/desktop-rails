# frozen_string_literal: true

require "cgi/escape"
require "fileutils"
require "find"
require "desktop_rails/packager/layout"

module DesktopRails
  module Packager
    # A macOS application bundle: <Name>.app, signed.
    #
    # The config goes in Contents/Resources, which is the shell's resource
    # directory on macOS and the only place a packaged shell reads it from.
    # Signing covers the executable first and the bundle last, the inside-out
    # order codesign needs, with the hardened runtime a notarized app must have.
    #
    # A bundled package adds ruby/, gems/ and app/ to Resources and the
    # launcher to MacOS/, and signs more: every loadable binary, then the
    # interpreter, then the launcher, the executable and the bundle, each with
    # the entitlements. They matter on the interpreter, because the app's
    # executable is a shell or a launcher script and `ruby` is the process that
    # dlopens the extensions: without disable-library-validation the dlopen is
    # refused, and without allow-unsigned-executable-memory the kernel kills
    # the process.
    class MacApp < Layout
      ICON_FILE = "AppIcon"

      # The entitlements a bundled app's code is signed with. In the gem, so a
      # gem installed from GitHub or RubyGems packages with no checkout.
      ENTITLEMENTS = File.expand_path("entitlements.plist", __dir__)

      # "-" signs ad hoc, which is all a build that is not being distributed
      # needs, and the default.
      def initialize(identity: "-", entitlements: nil, **options)
        super(**options)
        @identity = identity.to_s.strip.empty? ? "-" : identity.to_s
        @entitlements = entitlements
        @icon = false
      end

      attr_reader :identity, :entitlements

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

      def bundle_dir
        resources
      end

      def launcher_path
        contents.join("MacOS", "launch")
      end

      # The config sits in Resources, and the launcher beside the executable.
      def launcher_command
        "../MacOS/launch"
      end

      def launcher_template
        "launch-macos.sh.erb"
      end

      def interpreter_path
        resources.join("ruby", "bin", "ruby")
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

      def codesign_base
        base = [ "codesign", "--force", "--timestamp=none", "--options", "runtime" ]
        base += [ "--entitlements", entitlements.to_s ] if entitlements
        base + [ "--sign", identity ]
      end

      # The extensions and libraries a bundled package carries. Signed first,
      # and allowed to fail one by one: a file with a .so name that is not
      # Mach-O is not code, and was never a reason to refuse the package.
      def nested_binaries
        return [] unless File.directory?(resources)

        Find.find(resources.to_s).select do |path|
          path.end_with?(".dylib", ".bundle", ".so") && File.file?(path) && !File.symlink?(path)
        end.sort
      end

      def nested_signing_commands
        nested_binaries.map { |path| codesign_base + [ path ] }
      end

      # Inside-out: the interpreter and the launcher when the package carries
      # them, the executable, then the bundle that seals it together with
      # Info.plist and the config. Everything in MacOS/ counts as code, scripts
      # included: an unsigned launcher there makes the bundle's signature
      # invalid with "code object is not signed at all", which reads like a
      # problem with the binary and is not. A config edited after this breaks
      # the seal, which is the point — see README "Where the config is read
      # from".
      def signing_commands
        paths = []
        paths << interpreter_path if File.file?(interpreter_path)
        paths << launcher_path if File.file?(launcher_path) && launcher_path != executable_path
        paths << executable_path
        paths << root
        paths.map { |path| codesign_base + [ path.to_s ] }
      end

      def verify_command
        [ "codesign", "--verify", "--strict", "--deep", root.to_s ]
      end

      def finish!
        File.write(contents.join("Info.plist"), info_plist)
        nested = nested_signing_commands
        signed = nested.count { |argv| call_quietly(argv) }
        signing_commands.each { |argv| run!(argv, quiet: true) }
        run!(verify_command)
        log.call("  signed #{"#{signed} of #{nested.size} nested binaries, " unless nested.empty?}" \
                 "#{identity == "-" ? "ad hoc" : identity}, and verified")
        self
      end
    end
  end
end

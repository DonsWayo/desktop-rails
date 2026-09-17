# frozen_string_literal: true

require "tmpdir"
require "desktop_rails/packager"
require "desktop_rails/tooling/command"

module DesktopRails
  module Tooling
    # Notarises and staples a signed .app, then checks Gatekeeper accepts it.
    #
    # This is the step that makes a downloaded app open on someone else's Mac.
    # Measured on macOS 26.5.1: an ad-hoc signed bundle is `rejected` by `spctl`
    # with "no usable signature", quarantined or not. So this is not optional
    # polish — without it the app cannot be distributed at all.
    #
    # Needs a real identity, which is the one thing the rest of the pipeline does
    # not: an Apple Developer Program membership, a "Developer ID Application"
    # certificate in the keychain, and an app-specific password or API key,
    # stored once as a notarytool keychain profile:
    #
    #   xcrun notarytool store-credentials notary \
    #     --apple-id you@example.com --team-id TEAMID --password <app-specific>
    class Notarization
      DEFAULT_PROFILE = "notary"

      attr_reader :app, :identity, :keychain_profile, :entitlements

      def initialize(app:, identity: nil, keychain_profile: nil, entitlements: nil, runner: Command.new, log: $stdout)
        @app = File.expand_path(app.to_s)
        @identity = identity
        @keychain_profile = keychain_profile || DEFAULT_PROFILE
        @entitlements = entitlements || Packager::MacApp::ENTITLEMENTS
        @runner = runner
        @log = log
      end

      def resources
        File.join(app, "Contents", "Resources")
      end

      def interpreter
        File.join(resources, "ruby", "bin", "ruby")
      end

      # A real timestamp and the hardened runtime, both of which the notary
      # service requires and an ad-hoc signature does without.
      def codesign_argv(path)
        [ "codesign", "--force", "--timestamp", "--options", "runtime",
          "--entitlements", entitlements, "--sign", identity, path ]
      end

      def nested_binaries
        Find.find(resources).select do |path|
          File.file?(path) && !File.symlink?(path) && path.end_with?(".dylib", ".bundle", ".so")
        end.sort
      end

      # Everything in Contents/MacOS counts as code, the launcher script
      # included, and packaging signed it ad-hoc. The shell script this replaced
      # re-signed only Resources, which would have left the shell binary and the
      # launcher with signatures the notary service does not accept.
      def executables
        dir = File.join(app, "Contents", "MacOS")
        return [] unless File.directory?(dir)

        Dir.children(dir).map { |name| File.join(dir, name) }.select { |path| File.file?(path) }.sort
      end

      # Inside-out, and the entitlements go on the interpreter: the app's main
      # executable is a launcher script, and `ruby` is what dlopens the
      # extensions. Anything signed after its container invalidates the
      # container's seal.
      def signing_order
        nested_binaries + [ interpreter ] + executables + [ app ]
      end

      # notarytool takes an archive, not a bundle.
      def archive_argv(zip)
        [ "ditto", "-c", "-k", "--keepParent", app, zip ]
      end

      def submit_argv(zip)
        [ "xcrun", "notarytool", "submit", zip, "--keychain-profile", keychain_profile, "--wait" ]
      end

      def staple_argv
        [ "xcrun", "stapler", "staple", app ]
      end

      def verification_argvs
        [ [ "codesign", "--verify", "--strict", "--deep", "--verbose=2", app ],
          [ "spctl", "-a", "-vvv", app ] ]
      end

      # The Developer ID certificates `security` can see, for the message that
      # says which identity to pass.
      def self.developer_ids(find_identity_output)
        find_identity_output.to_s.lines.map(&:strip).select { |line| line.include?("Developer ID Application") }
      end

      def validate!
        raise MissingPrerequisite, "--app must be a .app bundle, got #{app}" unless File.directory?(app)
        unless entitlements && File.file?(entitlements)
          raise MissingPrerequisite, "No entitlements file at #{entitlements}; pass --entitlements."
        end
        return if identity && !identity.empty?

        listed = self.class.developer_ids(@runner.capture([ "security", "find-identity", "-v", "-p", "codesigning" ]).output)
        raise MissingPrerequisite, <<~MSG
          --identity is required. Available Developer ID certificates:
          #{listed.empty? ? "  none in the keychain" : listed.map { |line| "  #{line}" }.join("\n")}
        MSG
      end

      def notarize!
        validate!

        step "Re-signing with the real identity"
        # Every signature has to succeed. A nested binary left with its ad-hoc
        # signature is exactly what the notary service rejects, twenty minutes
        # into a submission, so it is better refused here.
        signing_order.each { |path| @runner.run(codesign_argv(path)) }
        @log.puts "  signed #{nested_binaries.size} nested binaries, the interpreter, " \
                  "#{executables.size} executables and the bundle"

        step "Submitting to the notary service"
        Dir.mktmpdir("desktop-rails-notarize-") do |scratch|
          zip = File.join(scratch, "#{File.basename(app, ".app")}.zip")
          @runner.run(archive_argv(zip))
          @runner.run(submit_argv(zip))
        end

        step "Stapling"
        @runner.run(staple_argv)

        step "Verifying the way Gatekeeper will"
        verification_argvs.each { |argv| @runner.run(argv) }
        @log.puts
        @log.puts "  A downloaded copy carries com.apple.quarantine. Test that too:"
        @log.puts "    xattr -w com.apple.quarantine '0083;0;Safari;' <copy>.app && spctl -a -vvv <copy>.app"
        app
      end

      private

      def step(message)
        @log.puts "\n\e[1m==> #{message}\e[0m"
      end
    end
  end
end

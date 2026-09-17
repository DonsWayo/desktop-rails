# frozen_string_literal: true

require "fileutils"
require "tempfile"
require "desktop_rails/tooling/command"

module DesktopRails
  module Tooling
    # Signing what tauri-plugin-updater installs.
    #
    # The plugin verifies every downloaded bundle against a minisign public key
    # before it installs anything, so an app without a keypair has no update
    # path. The bytes — Ed25519, BLAKE2b, scrypt and minisign's file formats —
    # are updater/updater-cli.mjs beside this file, which the JavaScript suite and the
    # shell's own Rust tests hold to what the plugin accepts. This is the part
    # around it: arguments, defaults, where keys live, what is printed.
    #
    # The password is only ever read from DESKTOP_RAILS_SIGNING_PASSWORD, never
    # from this tool's arguments: arguments are visible to every process on the
    # machine through ps.
    module Updater
      # What the plugin parses as a version. A manifest with anything else looks
      # fine until an installed app silently decides there is nothing newer.
      SEMVER = /\Av?\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)*\z/

      # `<os>-<arch>`, where the plugin calls macOS "darwin". A key the running
      # app does not recognise reads as "no update available".
      TARGET = /\A(darwin|linux|windows)-(x86_64|aarch64|i686|armv7)\z/

      PASSWORD_VARIABLE = "DESKTOP_RAILS_SIGNING_PASSWORD"
      KEY_VARIABLE = "DESKTOP_RAILS_SIGNING_KEY"

      # In the gem, so signing needs Node and nothing from a checkout.
      CLI_SCRIPT = File.expand_path("updater/updater-cli.mjs", __dir__)

      module_function

      def cli_path(env: ENV)
        Paths.presence(env["DESKTOP_RAILS_UPDATER_CLI"]) || CLI_SCRIPT
      end

      def cli!(env: ENV)
        path = cli_path(env: env)
        return path if path && File.file?(path)

        raise MissingPrerequisite, <<~MSG
          Could not find #{path}, which does the signing.

          It ships in this gem. If DESKTOP_RAILS_UPDATER_CLI is set, point it at an
          updater-cli.mjs that exists, or unset it.
        MSG
      end

      def node!(env: ENV)
        Tooling.which("node", env: env) || raise(MissingPrerequisite, "node is required (see mise: node)")
      end

      # The target for the machine this runs on, for when none was given.
      def host_target(host_os: RbConfig::CONFIG["host_os"], host_cpu: RbConfig::CONFIG["host_cpu"])
        os = { macos: "darwin", linux: "linux", windows: "windows" }.fetch(Tooling.platform(host_os))
        arch = case host_cpu.to_s
        when /\A(arm64|aarch64)\z/ then "aarch64"
        when /\A(x86_64|amd64|x64)\z/ then "x86_64"
        else raise MissingPrerequisite, "--target is required: cannot map #{host_cpu}"
        end
        "#{os}-#{arch}"
      end

      # Makes the keypair. Once, ever, per app.
      class KeyGeneration
        attr_reader :name, :dir

        def initialize(name: nil, dir: nil, force: false, env: ENV, runner: Command.new, log: $stdout)
          @name = name || "updater"
          @dir = File.expand_path(dir || ".signing")
          @force = force
          @env = env
          @runner = runner
          @log = log
        end

        def secret_path
          File.join(dir, "#{name}.key")
        end

        def public_path
          File.join(dir, "#{name}.pub")
        end

        # An empty password is allowed and matches what
        # `tauri signer generate --password ""` produces.
        def generate_argv(node:, cli:)
          [ node, cli, "generate", "--secret", secret_path, "--public", public_path,
            "--password", @env[PASSWORD_VARIABLE].to_s, "--comment", "desktop-rails #{name} secret key" ]
        end

        def generate!
          # Overwriting a key is the one mistake here that cannot be undone:
          # every installed copy only accepts bundles signed by the old one.
          if File.exist?(secret_path) && !@force
            raise Error, "#{secret_path} already exists.\n" \
                         "Pass --force only if you are certain nothing has shipped signed by it."
          end

          node = Updater.node!(env: @env)
          cli = Updater.cli!(env: @env)
          FileUtils.mkdir_p(dir)
          FileUtils.chmod(0o700, dir)

          key_id, pubkey = @runner.capture!(generate_argv(node: node, cli: cli)).lines.map(&:strip)
          @log.puts summary(key_id, pubkey)
          pubkey
        end

        def summary(key_id, pubkey)
          <<~SUMMARY

              key id      #{key_id}
              secret key  #{secret_path}   (mode 0600, never commit this)
              public key  #{public_path}

            Put this in desktop-rails.config.json — one generic shell binary reads its
            updater settings from there, so this is per app, not per build:

              "updater": {
                "endpoints": ["https://example.com/updates/latest.json"],
                "pubkey": "#{pubkey}"
              }

            For CI, hand the signing job the secret key and its password as secrets:

              #{KEY_VARIABLE}       the contents of #{name}.key
              #{PASSWORD_VARIABLE}  the password you just used

          SUMMARY
        end
      end

      # Signs a built update bundle and adds it to the manifest the shell
      # fetches. Run once per platform against the same manifest to build one
      # covering all of them.
      #
      # The bundle must be what the plugin knows how to install on that platform:
      # a .app.tar.gz on macOS, an .AppImage.tar.gz on Linux, the NSIS or MSI
      # installer on Windows. Signing something else produces a manifest that
      # verifies and then fails to install.
      class Signing
        attr_reader :artifact, :version, :url, :notes, :notes_file, :pub_date

        def initialize(artifact:, version:, url:, target: nil, key: nil, public_key: nil, manifest: nil, sig: nil,
                       notes: nil, notes_file: nil, pub_date: nil, env: ENV, host_os: RbConfig::CONFIG["host_os"],
                       host_cpu: RbConfig::CONFIG["host_cpu"], runner: Command.new, log: $stdout, clock: -> { Time.now })
          @artifact = artifact && File.expand_path(artifact.to_s)
          @version = version
          @url = url
          @target = target
          @key = File.expand_path(key || File.join(".signing", "updater.key"))
          @public_key = public_key && File.expand_path(public_key)
          @manifest = manifest && File.expand_path(manifest)
          @sig = sig && File.expand_path(sig)
          @notes = notes
          @notes_file = notes_file
          @pub_date = pub_date
          @env = env
          @host_os = host_os
          @host_cpu = host_cpu
          @runner = runner
          @log = log
          @clock = clock
        end

        def target
          @target ||= Updater.host_target(host_os: @host_os, host_cpu: @host_cpu).tap do |guessed|
            @log.puts "  target not given; using this machine's: #{guessed}"
          end
        end

        def manifest
          @manifest || File.join(File.dirname(artifact), "latest.json")
        end

        def sig
          @sig || "#{artifact}.sig"
        end

        # Beside the secret key unless named: key.key and key.pub are how
        # generate-key writes them.
        def public_key(key_path = @key)
          @public_key || key_path.sub(/\.key\z/, "") + ".pub"
        end

        # Caught here rather than at update time, because a manifest with a bad
        # version or an unknown platform key looks fine until an installed app
        # silently decides there is nothing to update to.
        def validate!
          raise Error, "--artifact must be a file" unless artifact && File.file?(artifact)
          raise Error, "--version is required" if version.to_s.empty?
          raise Error, "--url is required (where the artifact will be downloaded from)" if url.to_s.empty?
          raise Error, "--version must be semver, got: #{version}" unless version.match?(SEMVER)
          return if target.match?(TARGET)

          raise Error, "--target must be <darwin|linux|windows>-<x86_64|aarch64|i686|armv7>, got: #{target}"
        end

        # minisign's trusted comment: signed along with the file, and shown by
        # anything that verifies it.
        def trusted_comment
          "timestamp:#{@clock.call.to_i}\tfile:#{File.basename(artifact)}\tversion:#{version}\thashed"
        end

        def sign_argv(node:, cli:, key:)
          [ node, cli, "sign", "--key", key, "--artifact", artifact, "--sig", sig,
            "--password", @env[PASSWORD_VARIABLE].to_s, "--comment", trusted_comment ]
        end

        def verify_argv(node:, cli:, public_key:)
          [ node, cli, "verify", "--public", public_key, "--artifact", artifact, "--sig", sig ]
        end

        def manifest_argv(node:, cli:)
          argv = [ node, cli, "manifest", "--manifest", manifest, "--version", version, "--target", target,
                   "--url", url, "--sig", sig ]
          argv += [ "--notes", notes ] if notes
          argv += [ "--notes-file", notes_file ] if notes_file
          argv += [ "--pub-date", pub_date ] if pub_date
          argv
        end

        def sign!
          validate!
          node = Updater.node!(env: @env)
          cli = Updater.cli!(env: @env)

          with_key do |key|
            step "Signing #{File.basename(artifact)} (#{Tooling.human_size(File.size(artifact))})"
            @runner.capture!(sign_argv(node: node, cli: cli, key: key))
            @log.puts "  #{sig}"

            # Verifying here, against the public half, is what catches a wrong
            # password or a key that does not match the pubkey already shipped
            # in installed apps — before a broken release is published rather
            # than after nobody can update.
            # A key handed over in the environment has no .pub beside it, so
            # the check then needs --public.
            public_path = public_key(key)
            if File.file?(public_path)
              step "Verifying against #{File.basename(public_path)}"
              @log.puts "  #{@runner.capture!(verify_argv(node: node, cli: cli, public_key: public_path)).strip}"
            else
              @log.puts "  no public key beside the secret key; skipping the read-back check"
            end
          end

          step "Manifest"
          platforms = @runner.capture!(manifest_argv(node: node, cli: cli)).strip
          @log.puts "  #{manifest}"
          @log.puts "  version #{version} for: #{platforms}"

          step "Publish"
          @log.puts <<~NEXT
            Upload the artifact so it is reachable at exactly:
              #{url}
            Serve the manifest at the URL in this app's "updater.endpoints".
            Both must be https — the plugin refuses plain http in a release build.
          NEXT
          manifest
        end

        private

        # CI hands the key over as a secret rather than a file on disk. It is
        # written to a file only this user can read, for only as long as the
        # signing takes.
        def with_key
          secret = @env[KEY_VARIABLE].to_s
          if secret.empty?
            raise Error, "No signing key at #{@key} — run `desktop-rails-tool updater generate-key` first" unless File.file?(@key)

            return yield(@key)
          end

          file = Tempfile.new([ "desktop-rails-signing", ".key" ])
          begin
            File.chmod(0o600, file.path)
            file.write("#{secret}\n")
            file.close
            yield file.path
          ensure
            file.close!
          end
        end

        def step(message)
          @log.puts "\n\e[1m==> #{message}\e[0m"
        end
      end
    end
  end
end

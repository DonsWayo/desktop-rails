# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "desktop_rails/packager"
require "desktop_rails/packager/path_gems"
require "desktop_rails/packager/ruby_requirement"
require "desktop_rails/packager/runtime"
require "desktop_rails/packager/tree_copy"
require "desktop_rails/packager/windows_gem_probe"
require "desktop_rails/packaging"
require "desktop_rails/tooling/prune"

module DesktopRails
  # A Rails app with its own Ruby, in this platform's package layout: what
  # `bin/rails desktop:package` builds and `desktop-rails-tool package` builds
  # from a checkout or CI.
  #
  # It used to be three scripts, pack.sh, pack-linux.sh and pack-windows.ps1,
  # and every fix to one of them had to be found missing from the other two
  # first: Linux and Windows went months without vendoring path gems or
  # writing the bundle groups, and Windows kept a gem directory named for Ruby
  # 3.4 after the runtime moved on. Now there is one sequence of steps, and
  # the layouts in DesktopRails::Packager say only where things go.
  #
  # Each step exists because something was measured:
  #
  #   * The interpreter must be relocatable, which is desktop:runtime's job;
  #     this copies it in, gems beside it.
  #   * Never `rails server`. railties creates tmp/cache, tmp/pids and
  #     tmp/sockets under Rails.root ignoring config.paths, which is EACCES in
  #     a read-only package. boot.rb starts Puma from config.ru instead.
  #   * Everything the app writes goes to a data directory outside the
  #     package, which the launcher exports as DESKTOP_DATA_DIR.
  #   * The packed copy of the app is repaired, never the developer's own:
  #     path gems are vendored, the Ruby requirement is made to accept the
  #     runtime, and .bundle/config leaves out the groups the gems were
  #     installed without.
  #   * On macOS, signing runs inside-out with the entitlements on the
  #     interpreter. See Packager::MacApp.
  class BundledPackage
    DEFAULT_VERSION = "1.0"

    # Not everything under the app belongs in what ships. .desktop-rails/
    # holds the interpreter, the gems and earlier builds, all of which are
    # copied in their own right, so without it each package carried them twice
    # and then a copy of the previous package. storage/ holds the developer's
    # own databases. tmp/, log/, .git/ and node_modules/ at any depth are build
    # and development state.
    APP_EXCLUDES = %w[tmp/ log/ .git/ node_modules/ /.desktop-rails/ /storage/].freeze

    # The credentials keys stay behind when the app has a desktop environment,
    # which generates its own secret_key_base, so nothing in it needs them. An
    # app packaged in production has no other source for that secret, so its
    # keys still ship; a package a stranger downloads can then decrypt the
    # app's credentials, which is a reason to generate the desktop environment.
    KEY_EXCLUDES = %w[/config/master.key /config/credentials/*.key].freeze

    # The gems were installed without the development and test groups, so the
    # app must not ask for them at boot either, or Bundler dies on GemNotFound
    # for rubocop and web-console. .bundle/config travels with the app, which
    # is how a deployed Rails app says the same thing, and does not depend on
    # the launcher.
    BUNDLE_CONFIG = %(---\nBUNDLE_WITHOUT: "development:test"\n)

    BOOT_TEMPLATE = File.expand_path("packager/templates/boot.rb", __dir__)

    # An app id names the data directory and is written into the launchers,
    # so it is held to the reverse-DNS shape that is safe in both.
    APP_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    attr_reader :app, :runtime, :gems, :shell, :name, :app_id, :out, :platform, :identity, :version,
                :update_url, :update_key

    def initialize(app:, runtime:, name:, app_id:, out:, gems: nil, shell: nil, platform: Packaging.platform,
                   identity: nil, version: nil, update_url: nil, update_key: nil, keep_dev: false,
                   appimage: false, runner: Packager.system_runner, prune_runner: nil,
                   log: ->(message) { puts message })
      @app = File.expand_path(app.to_s)
      @runtime = Packager::Runtime.new(runtime)
      @gems = Paths.presence(gems&.to_s)
      @shell = Paths.presence(shell&.to_s)
      @name = name.to_s
      @app_id = app_id.to_s
      @out = out
      @platform = platform.to_sym
      @identity = identity
      @version = Paths.presence(version&.to_s) || DEFAULT_VERSION
      @update_url = Paths.presence(update_url&.to_s)
      @update_key = Paths.presence(update_key&.to_s)
      @keep_dev = keep_dev
      @appimage = appimage
      @runner = runner
      @prune_runner = prune_runner
      @log = log
    end

    def layout
      @layout ||= begin
        options = { out: out, name: name, app_id: app_id, version: version, runner: @runner, log: @log,
                    executable_name: shell ? File.basename(shell) : "launch" }
        case platform
        when :macos
          options[:identity] = identity
          options[:entitlements] = Packager::MacApp::ENTITLEMENTS
        when :linux
          options[:appimage] = @appimage
        end
        Packager.layout_for(platform, **options)
      end
    end

    def desktop_environment?
      File.file?(File.join(app, "config", "environments", "desktop.rb"))
    end

    def app_excludes
      APP_EXCLUDES + (desktop_environment? ? KEY_EXCLUDES : [])
    end

    # The value the shell's updater reads as `pubkey`: the whole minisign
    # public key file, base64, as `tauri signer` writes it. Checked to be a
    # key first, because a wrong file here is an app that can never update.
    def update_pubkey
      return nil unless update_key

      contents = File.read(update_key)
      lines = contents.strip.split("\n")
      decoded = Base64.decode64((lines.size > 1 ? lines[1] : lines[0]).to_s.strip)
      unless decoded.bytesize == 42
        raise Packager::InvalidInput, "#{update_key} is not a minisign public key (desktop-rails-tool updater generate-key makes one)."
      end

      Base64.strict_encode64(contents)
    end

    # The shell runs the bundled interpreter through the launcher, not a
    # developer's Ruby. The updater block is written only when both halves were
    # given: the shell treats a half-filled one as "not configured" anyway.
    def config
      config = {
        "app_name" => name,
        "server_url" => "http://127.0.0.1:0",
        "window" => { "width" => 1100, "height" => 800 },
        "server" => { "command" => layout.launcher_command, "directory" => "." }
      }
      if update_url
        config["updater"] = { "endpoints" => [ update_url ], "pubkey" => update_pubkey, "current_version" => version }
      end
      config
    end

    def validate!
      raise Packager::InvalidInput, "#{app} is not a directory; point at a Rails app." unless File.directory?(app)
      raise Packager::InvalidInput, "#{app} has no config.ru. Is it a Rails app?" unless File.file?(File.join(app, "config.ru"))
      raise Packager::InvalidInput, "#{runtime.dir} has no bin/ruby, so it is not a Ruby to package." unless runtime.valid?
      raise ArgumentError, "A package needs a name" if name.strip.empty?
      unless app_id.match?(APP_ID)
        raise Packager::InvalidInput, "The app id #{app_id.inspect} must be letters, digits, dots, dashes and underscores, " \
                                      "such as com.example.ledger."
      end
      if gems && !File.directory?(gems)
        raise Packager::InvalidInput, "The gems directory #{gems} does not exist."
      end
      if shell && !(File.file?(shell) && (platform == :windows || File.executable?(shell)))
        raise Packager::InvalidInput, "The shell #{shell} is not an executable file."
      end

      # The updater takes the endpoint and the key together or not at all: an
      # endpoint without a key would mean installing whatever that server
      # offered.
      if update_url && !update_key
        raise Packager::InvalidInput, "An update URL needs the update key: an unsigned update is worse than none."
      end
      raise Packager::InvalidInput, "An update key needs an update URL." if update_key && !update_url
      raise Packager::InvalidInput, "The update key #{update_key} does not exist." if update_key && !File.file?(update_key)

      self
    end

    def build
      validate!
      # Read before anything is copied, so a runtime that cannot be described
      # stops the build before minutes of copying.
      abi = runtime.abi
      runtime_version = runtime.version
      packed_app = layout.bundle_dir.join("app")

      step "Assembling #{File.basename(layout.root.to_s)}"
      layout.prepare!
      Packager::TreeCopy.copy(runtime.dir, layout.bundle_dir.join("ruby"))
      Packager::TreeCopy.copy(gems, layout.bundle_dir.join("gems")) if gems
      Packager::TreeCopy.copy(app, packed_app, excludes: app_excludes)
      FileUtils.cp(BOOT_TEMPLATE, packed_app.join("boot.rb"))
      @log.call("  Ruby #{runtime_version}, #{gems ? "gems" : "no gems"} and the app copied")

      step "Repairing the packed copy of the app"
      Packager::PathGems.new(original: app, packed: packed_app, log: @log).vendor!
      Packager::RubyRequirement.new(packed: packed_app, runtime_version: runtime_version,
                                    runtime_patchlevel: runtime.patchlevel, log: @log).apply!
      FileUtils.mkdir_p(packed_app.join(".bundle"))
      File.write(packed_app.join(".bundle", "config"), BUNDLE_CONFIG)
      if platform == :windows
        changed = Packager::WindowsGemProbe.apply(layout.bundle_dir.join("ruby"))
        @log.call(changed.empty? ? "  no gem writability probe to disable" : "  gem writability probe disabled")
      end

      if shell
        layout.install_executable(shell)
        layout.write_config(JSON.pretty_generate(config) + "\n")
        @log.call("  shell embedded: #{File.basename(layout.executable_path.to_s)}")
        @log.call("  updates: #{update_url} (v#{version})") if update_url
      end
      layout.write_launcher(abi: abi)

      step "Pruning"
      Tooling::Prune.new(layout.bundle_dir, keep_dev: @keep_dev, runner: @prune_runner || Tooling::Command.new,
                                            log: LogWriter.new(@log)).run!

      step platform == :macos ? "Signing (identity: #{layout.identity})" : "Packaging"
      layout.finish!
      layout
    end

    private

    def step(message)
      @log.call("\n==> #{message}")
    end

    # Prune reports through `puts`; everything here reports through a callable.
    class LogWriter
      def initialize(log)
        @log = log
      end

      def puts(message = "")
        @log.call(message.to_s)
      end
    end
  end
end

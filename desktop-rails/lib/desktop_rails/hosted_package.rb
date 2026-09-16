# frozen_string_literal: true

require "ipaddr"
require "json"
require "uri"
require "desktop_rails/packager"
require "desktop_rails/packaging"

module DesktopRails
  # A desktop app for a server you already run: the prebuilt shell and a
  # desktop-rails.config.json, in this platform's package layout. No Rails app,
  # no interpreter and no gems go inside, and nothing is compiled — the shell is
  # the one desktop:shell downloads.
  #
  # The config is the app's whole trust boundary. server_url is the one origin
  # the bridge answers, and every capability that reaches the machine (shell,
  # sudo, filesystem roots, clipboard reads) is off unless the config turns it
  # on. So it is checked here, before it is sealed into a package that will run
  # on other people's machines, for the mistakes that would widen that boundary
  # or silently do nothing.
  class HostedPackage
    class InvalidConfig < StandardError; end

    # The top-level keys the shell reads (DesktopRailsConfig in
    # src-tauri/src/window.rs). The shell ignores keys it does not know, so a
    # misspelt "shel" would ship a config that quietly means something else.
    KNOWN_KEYS = %w[
      server_url path_configuration_url app_name user_agent window filesystem
      sudo shell clipboard navigation server updater notifications shortcuts
    ].freeze

    # Modifier names the shell's accelerator parser accepts (global-hotkey).
    MODIFIERS = %w[
      alt option control ctrl command cmd super shift
      commandorcontrol commandorctrl cmdorctrl cmdorcontrol
    ].freeze

    DEFAULT_VERSION = "1.0"

    attr_reader :config, :name, :app_id, :shell, :out, :platform, :icon, :identity, :version

    # Read a config file, apply overrides, and check the result.
    #
    # `server_url` replaces the file's, which lets one checked-in config serve
    # a staging and a production build. `name` fills app_name when the file has
    # none, so the window title matches the package.
    def self.load_config(path: nil, server_url: nil, name: nil)
      config =
        if path
          unless File.file?(path.to_s)
            raise InvalidConfig, "#{path} does not exist. Point DESKTOP_RAILS_CONFIG at a desktop-rails.config.json."
          end

          begin
            JSON.parse(File.read(path.to_s))
          rescue JSON::ParserError => e
            raise InvalidConfig, "#{path} is not valid JSON: #{e.message}"
          end
        else
          {}
        end
      raise InvalidConfig, "#{path} must hold a JSON object" unless config.is_a?(Hash)

      config["server_url"] = server_url.to_s if Paths.presence(server_url)
      config["app_name"] ||= name.to_s if Paths.presence(name)
      validate!(config)
    end

    def self.validate!(config)
      unknown = config.keys - KNOWN_KEYS
      unless unknown.empty?
        raise InvalidConfig, "Unknown key#{"s" if unknown.size > 1} #{unknown.join(", ")} in the config. " \
                             "The shell reads #{KNOWN_KEYS.join(", ")}, and ignores anything else."
      end

      check_server_url!(config["server_url"])

      if config.dig("server", "command")
        raise InvalidConfig, "The config has a server.command. A hosted app starts no server: that command " \
                             "would run on every machine the app is installed on. Remove the server block."
      end

      check_updater!(config["updater"]) if config.key?("updater")
      check_summon!(config.dig("shortcuts", "summon")) if config["shortcuts"].is_a?(Hash)
      config
    end

    # The shell logs a summon shortcut it cannot parse and starts without it,
    # which in a shipped app nobody reads. So the same rules are checked here:
    # modifiers first, one key last, and a modifier that is not Shift, since a
    # global shortcut without one takes ordinary typing from every application.
    def self.check_summon!(summon)
      return if summon.nil?

      tokens = summon.is_a?(String) ? summon.split("+", -1).map { |token| token.strip.downcase } : []
      *modifiers, key = tokens
      valid = tokens.size >= 2 && tokens.none?(&:empty?) && !MODIFIERS.include?(key) &&
              modifiers.all? { |modifier| MODIFIERS.include?(modifier) } &&
              modifiers.any? { |modifier| modifier != "shift" }
      return if valid

      raise InvalidConfig, "shortcuts.summon #{summon.inspect} is not a global shortcut the shell accepts. " \
                           "Name one or more modifiers, at least one of them not Shift, then one key, " \
                           "as in \"CmdOrCtrl+Shift+Space\"."
    end

    def self.check_server_url!(value)
      if value.to_s.strip.empty?
        raise InvalidConfig, "No server_url. Set it in the config, or pass DESKTOP_RAILS_SERVER_URL=https://app.example.com."
      end

      uri = begin
        URI.parse(value.to_s)
      rescue URI::InvalidURIError
        nil
      end
      unless uri.is_a?(URI::HTTP) && Paths.presence(uri.host)
        raise InvalidConfig, "server_url #{value} is not an http or https URL with a host."
      end

      return if uri.scheme == "https" || loopback?(uri.host)

      raise InvalidConfig, <<~MSG.strip
        server_url #{value} is plain http on a host other than this machine. That origin is what the
        bridge trusts, and over http anyone on the network path can serve pages as it. Use https.
      MSG
    end

    def self.loopback?(host)
      host = host.to_s.delete_prefix("[").delete_suffix("]")
      return true if host.casecmp?("localhost")

      IPAddr.new(host).loopback?
    rescue IPAddr::InvalidAddressError
      false
    end

    # The updater either verifies what it installs or is off. An endpoint
    # without a key would mean running whatever that server offered.
    def self.check_updater!(updater)
      endpoints = Array(updater.is_a?(Hash) ? updater["endpoints"] : nil)
      pubkey = updater.is_a?(Hash) ? updater["pubkey"].to_s.strip : ""
      if endpoints.empty? || pubkey.empty?
        raise InvalidConfig, "The updater block needs both endpoints and pubkey; with one missing the app would " \
                             "never update. Remove the block, or complete it (packaging/AUTO_UPDATE.md)."
      end
      insecure = endpoints.reject { |endpoint| endpoint.to_s.start_with?("https://") }
      return if insecure.empty?

      raise InvalidConfig, "Updater endpoints must be https (the shell refuses http in a release build): #{insecure.join(", ")}"
    end

    # One line per capability, saying what a page from server_url can reach on
    # the machine. Printed before packaging, so a widening is seen by whoever
    # builds the app rather than discovered by whoever audits it.
    def self.capability_summary(config)
      shell = config["shell"] || {}
      sudo = config["sudo"] || {}
      roots = Array(config.dig("filesystem", "allowed_roots"))
      internal = Array(config.dig("navigation", "internal_hosts"))
      endpoints = Array(config.dig("updater", "endpoints"))

      [
        "origin      #{config["server_url"]} is the only origin that may call the bridge",
        "shell       #{allowlist_summary(shell)}",
        "sudo        #{allowlist_summary(sudo)}",
        "filesystem  #{roots.empty? ? "only files and folders the user picks or drops" : "those, and under #{roots.join(", ")}"}",
        "clipboard   #{config.dig("clipboard", "read") ? "read and write" : "write only"}",
        "links       #{internal.empty? ? "other sites open in the browser" : "#{internal.join(", ")} may also load in the window, without the bridge"}",
        "updates     #{endpoints.empty? ? "off" : "signed, from #{endpoints.join(", ")}"}",
        "notify      #{config.dig("notifications", "enabled") == false ? "off" : "pages and Ruby may raise OS notifications"}",
        "shortcuts   #{shortcut_summary(config["shortcuts"] || {})}"
      ]
    end

    def self.shortcut_summary(shortcuts)
      pages = "pages may register global shortcuts that use a modifier"
      pages = "pages may not register global shortcuts" if shortcuts["enabled"] == false
      shortcuts["summon"] ? "#{pages}; #{shortcuts["summon"]} summons the window" : pages
    end

    def self.allowlist_summary(block)
      return "off" unless block["enabled"]

      commands = Array(block["allowed_commands"])
      commands.empty? ? "enabled, but no allowed_commands, so nothing runs" : "on: #{commands.join(", ")}"
    end

    def initialize(config:, name:, app_id:, shell:, out:, platform: Packaging.platform, icon: nil,
                   identity: nil, version: nil, runner: Packager.system_runner, log: ->(message) { puts message })
      @config = config
      @name = name
      @app_id = app_id
      @shell = shell
      @out = out
      @platform = platform
      @icon = Paths.presence(icon)
      @identity = identity
      @version = Paths.presence(version) || config.dig("updater", "current_version") || DEFAULT_VERSION
      @runner = runner
      @log = log
    end

    def layout
      @layout ||= begin
        options = { out: out, name: name, app_id: app_id, version: version, runner: @runner, log: @log,
                    executable_name: File.basename(shell.to_s) }
        options[:identity] = identity if platform.to_sym == :macos
        Packager.layout_for(platform, **options)
      end
    end

    def build
      unless shell && File.file?(shell.to_s)
        raise Packaging::MissingPrerequisite, <<~MSG
          No shell to package. A hosted app is the shell and its config, nothing else.

          Download the prebuilt one for this platform:

            bin/rails desktop:shell

          or point at one: DESKTOP_RAILS_SHELL=/path/to/desktop-rails
        MSG
      end
      if icon && !File.file?(icon.to_s)
        raise Packager::InvalidInput, "The icon #{icon} does not exist."
      end

      layout.prepare!
      layout.install_executable(shell)
      layout.write_config(JSON.pretty_generate(config) + "\n")
      if icon
        applied = layout.install_icon(icon)
        @log.call(applied ? "  icon: #{icon}" : "  icon: not applied; a #{platform} executable carries its icon inside it, so the shell's own stays")
      end
      layout.finish!
      layout
    end
  end
end

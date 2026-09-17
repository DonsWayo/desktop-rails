# frozen_string_literal: true

require "pathname"
require "rbconfig"
require "securerandom"
require "fileutils"

module DesktopRails
  # Where a packaged app is allowed to write.
  #
  # Rails has no concept of an OS data directory because a server owns its
  # deployment directory. A desktop app does not: the bundle is read-only and
  # code-signed on macOS, so tmp/, log/, storage/ and the database cannot live
  # under Rails.root. Every platform has a blessed location for this and they
  # disagree, so the answer has to be computed rather than configured.
  #
  #   DesktopRails.data_dir                  # => #<Pathname .../Application Support/dev.example.ledger>
  #   DesktopRails.data_dir(create: true)    # same, but it exists afterwards
  #
  # The launchers packaging writes already export DESKTOP_DATA_DIR, having
  # made the same decision in shell. That variable wins when it is set, so the
  # launcher and the Rails app can never disagree about where state lives.
  module Paths
    module_function

    # The per-platform directory this app owns.
    #
    # host_os and env are injectable so the other platforms' answers can be
    # tested from any one machine, which is the only way this stays honest.
    def data_dir(app_id: nil, create: false, host_os: RbConfig::CONFIG["host_os"], env: ENV)
      dir =
        if (override = presence(env["DESKTOP_DATA_DIR"]))
          Pathname.new(override)
        else
          base_dir(host_os: host_os, env: env).join(app_id || DesktopRails.app_id)
        end

      FileUtils.mkdir_p(dir) if create
      dir
    end

    # The parent every app on this platform puts its directory inside.
    def base_dir(host_os: RbConfig::CONFIG["host_os"], env: ENV)
      case platform(host_os)
      when :macos
        home(env).join("Library", "Application Support")
      when :windows
        # LOCALAPPDATA rather than APPDATA: this is machine-local state, not
        # something to drag across a roaming profile.
        Pathname.new(presence(env["LOCALAPPDATA"]) || home(env).join("AppData", "Local").to_s)
      else
        # The XDG base directory spec, which is what a Linux desktop expects.
        Pathname.new(presence(env["XDG_DATA_HOME"]) || home(env).join(".local", "share").to_s)
      end
    end

    def platform(host_os = RbConfig::CONFIG["host_os"])
      case host_os
      when /darwin|mac os/i           then :macos
      when /mswin|mingw|cygwin/i      then :windows
      else                                 :linux
      end
    end

    # A secret_key_base that survives restarts without a credentials key.
    #
    # A Rails app in a production-like environment refuses to boot without one,
    # and a desktop app has no operator to hand it a secret at deploy time.
    # Generating one on first run and keeping it in the data directory — mode
    # 0600, outside the signed bundle — is the closest thing to a keychain that
    # needs no platform code.
    def secret_key_base(app_id: nil, env: ENV)
      return env["SECRET_KEY_BASE"] if presence(env["SECRET_KEY_BASE"])

      file = data_dir(app_id: app_id, create: true, env: env).join("secret_key_base")
      return file.read.strip if file.exist? && !file.read.strip.empty?

      secret = SecureRandom.hex(64)
      file.write(secret)
      FileUtils.chmod(0o600, file)
      secret
    end

    def home(env = ENV)
      Pathname.new(presence(env["HOME"]) || Dir.home)
    end

    def presence(value)
      value if value && !value.to_s.strip.empty?
    end
  end
end

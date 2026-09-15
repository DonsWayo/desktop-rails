require "turbo_desktop/version"
require "turbo_desktop/engine" if defined?(Rails)
require "turbo_desktop/configuration"
require "turbo_desktop/detection"
require "turbo_desktop/paths"

require "turbo_desktop/native"

module TurboDesktop
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    # The per-platform directory this app may write to: Application Support on
    # macOS, %LOCALAPPDATA% on Windows, $XDG_DATA_HOME on Linux. See
    # TurboDesktop::Paths for why Rails cannot answer this itself.
    def data_dir(create: false, app_id: nil)
      Paths.data_dir(app_id: app_id || self.app_id, create: create)
    end

    def secret_key_base
      Paths.secret_key_base(app_id: app_id)
    end

    # The bundle identifier, which is also the name of the data directory. The
    # packers default to dev.turbodesktop.app; deriving it from the application
    # means two apps built by the same developer do not share state.
    def app_id
      Paths.presence(configuration.app_id) ||
        Paths.presence(ENV["TURBO_DESKTOP_APP_ID"]) ||
        "dev.turbodesktop.#{app_slug}"
    end

    # The display name: the .app's CFBundleName, the window title, the Linux
    # .desktop entry.
    def app_name
      Paths.presence(configuration.app_name) ||
        Paths.presence(ENV["TURBO_DESKTOP_APP_NAME"]) ||
        rails_app_name ||
        "Turbo Desktop App"
    end

    def app_slug
      name = rails_app_name || "app"
      slug = name.gsub(/([a-z\d])([A-Z])/, '\1-\2').downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      slug.empty? ? "app" : slug
    end

    private

    # Rails names the application module, and that is the only name a Rails app
    # has. It is absent outside Rails and in the gem's own tests, so every
    # caller has a fallback.
    def rails_app_name
      return nil unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

      name = Rails.application.class.name.to_s.split("::").first
      name if name && !name.empty?
    end
  end
end

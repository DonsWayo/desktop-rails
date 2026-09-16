require "desktop_rails/version"
require "desktop_rails/engine" if defined?(Rails)
require "desktop_rails/configuration"
require "desktop_rails/detection"
require "desktop_rails/paths"

require "desktop_rails/native"

module DesktopRails
  # configuration, configure and reset_configuration! live in
  # desktop_rails/configuration.rb.
  class << self
    # The per-platform directory this app may write to: Application Support on
    # macOS, %LOCALAPPDATA% on Windows, $XDG_DATA_HOME on Linux. See
    # DesktopRails::Paths for why Rails cannot answer this itself.
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
        Paths.presence(ENV["DESKTOP_RAILS_APP_ID"]) ||
        "dev.turbodesktop.#{app_slug}"
    end

    # The display name: the .app's CFBundleName, the window title, the Linux
    # .desktop entry.
    def app_name
      Paths.presence(configuration.app_name) ||
        Paths.presence(ENV["DESKTOP_RAILS_APP_NAME"]) ||
        rails_app_name ||
        "Desktop Rails App"
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

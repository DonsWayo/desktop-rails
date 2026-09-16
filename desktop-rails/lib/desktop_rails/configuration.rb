module DesktopRails
  # Defined beside the class rather than in desktop_rails.rb, so that
  # DesktopRails::Packaging can be loaded on its own — by the release workflow,
  # with no Rails or ActiveSupport installed — and still read the configuration.
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
  end

  class Configuration
    attr_accessor :path_configuration, :user_agent_pattern, :inspector_enabled,
                  :inspector_mount_path, :variant, :prepare_database

    # Packaging. Every one of these is nil by default and resolved at the point
    # of use, because the sensible answer depends on the Rails app and is not
    # known when this object is built. Set them in the initializer to override.
    attr_accessor :app_name, :app_id, :packaging_dir, :runtime_dir, :gems_dir,
                  :shell_binary, :dist_dir, :signing_identity,
                  :release_url, :release_version

    def initialize
      @path_configuration = default_path_configuration
      @user_agent_pattern = /Desktop Rails/
      @inspector_enabled = false
      # Rails variant set on requests from the desktop app, so views can be
      # written as show.html+desktop.erb. Set to nil to leave variants alone.
      @variant = :desktop
      # Where the engine is mounted; the inspector meta tag advertises assets
      # under this prefix. Override if you mount the engine elsewhere.
      @inspector_mount_path = "/desktop-rails"
      # Create, load and migrate the app's databases when the packaged app
      # boots. See DesktopRails::Database. Turn it off only for an app that
      # manages its own schema some other way.
      @prepare_database = true

      @app_name = nil
      @app_id = nil
      @packaging_dir = nil
      @runtime_dir = nil
      @gems_dir = nil
      @shell_binary = nil
      @dist_dir = nil
      # "-" is ad-hoc signing, which is what pack.sh defaults to and all an
      # unreleased build needs. A Developer ID goes here to ship.
      @signing_identity = nil
      # Where desktop:runtime and desktop:shell download from. nil means this
      # gem's own GitHub release for its own version; see
      # DesktopRails::Packaging.release_base_url.
      @release_url = nil
      @release_version = nil
    end

    def path_configuration_json
      @path_configuration.to_json
    end

    private

    def default_path_configuration
      {
        settings: {
          screenshots_enabled: false
        },
        rules: [
          { patterns: [ "/" ], properties: { presentation: "default" } }
        ]
      }
    end
  end
end

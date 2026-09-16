module DesktopRails
  class Configuration
    attr_accessor :path_configuration, :user_agent_pattern, :inspector_enabled,
                  :inspector_mount_path, :variant

    # Packaging. Every one of these is nil by default and resolved at the point
    # of use, because the sensible answer depends on the Rails app and is not
    # known when this object is built. Set them in the initializer to override.
    attr_accessor :app_name, :app_id, :packaging_dir, :runtime_dir, :gems_dir,
                  :shell_binary, :dist_dir, :signing_identity

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

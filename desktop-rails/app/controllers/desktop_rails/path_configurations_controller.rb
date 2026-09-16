module DesktopRails
  class PathConfigurationsController < ActionController::Base
    # GET /desktop-rails/path-configuration.json
    #
    # Returns the path configuration JSON that the desktop app uses
    # to determine how to present each URL (default, modal, new window, native).
    #
    # This endpoint mirrors the pattern used by Hotwire Native mobile apps.
    def show
      render json: DesktopRails.configuration.path_configuration
    end
  end
end

require "desktop_rails/view_helpers"
require "desktop_rails/detection"

module DesktopRails
  class Engine < ::Rails::Engine
    isolate_namespace DesktopRails

    config.to_prepare do
      ActionController::Base.include DesktopRails::Detection unless ActionController::Base < DesktopRails::Detection
      ActionView::Base.include DesktopRails::ViewHelpers unless ActionView::Base < DesktopRails::ViewHelpers
    end

    # desktop:runtime, desktop:package and desktop:run, available in the host
    # app as soon as the gem is in the Gemfile.
    rake_tasks do
      load File.expand_path("tasks/desktop.rake", __dir__)
    end

    # The shell writes one line of handshake to our stdin before anything
    # else. Read it at boot so `DesktopRails::Native` works everywhere in the
    # app, including from a background job with no page open.
    #
    # Exactly one line is consumed: the shell keeps the pipe open afterwards
    # so that closing it is the signal to exit, which is the only thing that
    # survives the shell being force-quit.
    initializer "desktop_rails.native_handshake" do
      DesktopRails::Native.read_handshake!
    rescue StandardError => e
      Rails.logger&.warn("[desktop_rails] no native handshake: #{e.class}: #{e.message}")
    end
  end
end

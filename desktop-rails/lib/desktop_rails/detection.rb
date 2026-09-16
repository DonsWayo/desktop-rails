module DesktopRails
  # Detects whether the current request is coming from a Desktop Rails app
  # by inspecting the User-Agent string.
  #
  # The Desktop Rails shell sets a User-Agent like:
  #   "Desktop Rails/0.1.0 (macOS; aarch64)"
  #
  # This mirrors how turbo-rails detects Turbo Native mobile apps.
  module Detection
    extend ActiveSupport::Concern

    included do
      helper_method :desktop_rails_app?, :desktop_rails_platform, :desktop_rails_arch

      before_action :set_desktop_rails_variant
    end

    # The variant list a request should end up with, or nil to leave it alone.
    #
    # Kept separate from the controller so the decision can be exercised on its
    # own. Adds to whatever variants are already set rather than replacing them:
    # an app may well be using variants for something else.
    def self.variant_for(current:, desktop:, configured:)
      return nil if configured.blank? || !desktop

      current = Array(current).map(&:to_sym)
      configured = configured.to_sym
      return nil if current.include?(configured)

      current + [ configured ]
    end

    # Returns true if the request is from a Desktop Rails app.
    def desktop_rails_app?
      request.user_agent.to_s.match?(DesktopRails.configuration.user_agent_pattern)
    end

    # Returns the desktop platform: "macos", "windows", "linux", or nil.
    def desktop_rails_platform
      return nil unless desktop_rails_app?

      ua = request.user_agent.to_s
      case ua
      when /macOS/i then "macos"
      when /Windows/i then "windows"
      when /Linux/i then "linux"
      else nil
      end
    end

    # Mark desktop requests with a Rails variant, so a whole template can be
    # written for the desktop app instead of branching inside a shared one:
    #
    #   app/views/orders/show.html.erb           # everyone
    #   app/views/orders/show.html+desktop.erb   # the desktop app
    #
    # Layouts pick it up too — layouts/application.html+desktop.erb. Rails falls
    # back to the plain template wherever no variant exists, so this costs
    # nothing until you add one.
    #
    # Set config.variant to nil to turn it off.
    def set_desktop_rails_variant
      variant = DesktopRails::Detection.variant_for(
        current: request.variant,
        desktop: desktop_rails_app?,
        configured: DesktopRails.configuration.variant
      )

      request.variant = variant if variant
    end

    # Returns the architecture: "aarch64", "x86_64", or nil.
    def desktop_rails_arch
      return nil unless desktop_rails_app?

      ua = request.user_agent.to_s
      case ua
      when /aarch64/i then "aarch64"
      when /x86_64/i then "x86_64"
      else nil
      end
    end
  end
end

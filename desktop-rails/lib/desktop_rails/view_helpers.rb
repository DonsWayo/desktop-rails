module DesktopRails
  module ViewHelpers
    # Returns true if the request is from a Desktop Rails app.
    def desktop_rails_app?
      request.user_agent.to_s.match?(DesktopRails.configuration.user_agent_pattern)
    end

    # Returns the desktop platform: "macos", "windows", "linux", or nil.
    def desktop_rails_platform
      return nil unless desktop_rails_app?

      case request.user_agent.to_s
      when /macOS/i then "macos"
      when /Windows/i then "windows"
      when /Linux/i then "linux"
      end
    end

    # Returns the architecture: "aarch64", "x86_64", or nil.
    def desktop_rails_arch
      return nil unless desktop_rails_app?

      case request.user_agent.to_s
      when /aarch64/i then "aarch64"
      when /x86_64/i then "x86_64"
      end
    end

    # Attribute name fragments we are willing to build a data-* attribute from.
    # Values are escaped by the tag helpers, but names are interpolated, so they
    # are restricted rather than escaped.
    BRIDGE_NAME_PATTERN = /\A[a-zA-Z0-9_-]+\z/

    # Renders a bridge component data attribute.
    #
    #   <%= tag.button "Export", **desktop_rails_bridge("menu-item", title: "Export PDF", shortcut: "Cmd+E") %>
    def desktop_rails_bridge(component, **options)
      validate_bridge_name!(component, "component")

      attrs = { "data-desktop-rails-bridge" => component.to_s }
      options.each do |key, value|
        validate_bridge_name!(key, "option name")
        attrs["data-desktop-rails-bridge-#{key}"] = value.to_s
      end
      attrs
    end

    # Conditionally render content only for desktop apps.
    def desktop_rails_only(&block)
      capture(&block) if desktop_rails_app?
    end

    # Conditionally render content only for web (non-desktop) users.
    def turbo_web_only(&block)
      capture(&block) unless desktop_rails_app?
    end

    # Returns true when the Dev Inspector is enabled in configuration.
    def desktop_rails_inspector?
      DesktopRails.configuration.inspector_enabled
    end

    # Emits the <meta> tag that enables the Dev Inspector in the browser, or nil
    # when the inspector is disabled. Place in your layout <head>; it is a no-op
    # in production unless you explicitly enable the inspector there.
    #
    # The tag also carries the same-origin URL of the inspector entry module
    # (served by this engine) so the desktop shell's desktop-rails.js can
    # import() it instead of guessing a relative path.
    #
    #   <%= desktop_rails_inspector_meta_tag %>
    def desktop_rails_inspector_meta_tag
      return nil unless desktop_rails_inspector?

      tag.meta(name: "desktop-rails-inspector", content: "enabled",
               data: { inspector_url: desktop_rails_inspector_url })
    end

    # Same-origin URL of the inspector entry module, under the engine's mount
    # path (configurable via config.inspector_mount_path).
    def desktop_rails_inspector_url
      "#{DesktopRails.configuration.inspector_mount_path.chomp("/")}/inspector.js"
    end

    # Subscribe this page to Turbo Streams broadcast with DesktopRails::Streams,
    # over server-sent events rather than Action Cable.
    #
    #   <%= desktop_stream_from "notes" %>
    #   <%= desktop_stream_from @project, :comments %>
    #
    # Renders Turbo's own <turbo-stream-source>, which opens an EventSource for
    # any URL that is not ws:// and applies each message as a Turbo Stream.
    def desktop_stream_from(*streamables, **attributes)
      signed = DesktopRails::Streams.signed_stream_name(streamables)
      src =
        if respond_to?(:desktop_rails) && desktop_rails.respond_to?(:stream_path)
          desktop_rails.stream_path(name: signed)
        else
          "#{DesktopRails.configuration.inspector_mount_path.chomp("/")}/stream?#{{ name: signed }.to_query}"
        end
      tag.turbo_stream_source(src: src, **attributes)
    end

    private

    def validate_bridge_name!(name, label)
      return if name.to_s.match?(BRIDGE_NAME_PATTERN)

      raise ArgumentError,
            "desktop_rails_bridge #{label} #{name.inspect} may only contain " \
            "letters, numbers, hyphens and underscores"
    end
  end
end

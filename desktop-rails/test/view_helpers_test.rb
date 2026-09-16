require "test_helper"

class ViewHelpersTestHost
  include DesktopRails::ViewHelpers

  attr_reader :request

  def initialize(user_agent)
    @request = StubRequest.new(user_agent)
  end

  # Stub capture for desktop_rails_only / turbo_web_only
  def capture(&block)
    block.call
  end

  # Minimal stub for Rails' tag.meta helper
  def tag
    @tag ||= Class.new do
      def meta(**attrs)
        flat = []
        attrs.each do |k, v|
          if k == :data && v.is_a?(Hash)
            v.each { |dk, dv| flat << %(data-#{dk.to_s.tr("_", "-")}="#{dv}") }
          else
            flat << %(#{k.to_s.tr("_", "-")}="#{v}")
          end
        end
        "<meta #{flat.join(" ")}>"
      end
    end.new
  end
end

class ViewHelpersTest < Minitest::Test
  DESKTOP_UA = "Desktop Rails/0.1.0 (macOS; aarch64)"
  BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"

  # --- desktop_rails_app? (duplicated in ViewHelpers) ---

  def test_view_helper_detects_desktop_app
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    assert host.desktop_rails_app?
  end

  def test_view_helper_rejects_browser
    host = ViewHelpersTestHost.new(BROWSER_UA)
    refute host.desktop_rails_app?
  end

  # --- desktop_rails_platform ---

  def test_view_helper_platform_macos
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    assert_equal "macos", host.desktop_rails_platform
  end

  def test_view_helper_platform_windows
    host = ViewHelpersTestHost.new("Desktop Rails/0.1.0 (Windows; x86_64)")
    assert_equal "windows", host.desktop_rails_platform
  end

  def test_view_helper_platform_linux
    host = ViewHelpersTestHost.new("Desktop Rails/0.1.0 (Linux; x86_64)")
    assert_equal "linux", host.desktop_rails_platform
  end

  def test_view_helper_platform_nil_when_not_desktop
    host = ViewHelpersTestHost.new(BROWSER_UA)
    assert_nil host.desktop_rails_platform
  end

  # --- desktop_rails_arch ---

  def test_view_helper_arch_aarch64
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    assert_equal "aarch64", host.desktop_rails_arch
  end

  def test_view_helper_arch_x86_64
    host = ViewHelpersTestHost.new("Desktop Rails/0.1.0 (macOS; x86_64)")
    assert_equal "x86_64", host.desktop_rails_arch
  end

  def test_view_helper_arch_nil_when_not_desktop
    host = ViewHelpersTestHost.new(BROWSER_UA)
    assert_nil host.desktop_rails_arch
  end

  # --- desktop_rails_bridge ---

  def test_bridge_returns_hash_with_component_name
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    result = host.desktop_rails_bridge("menu-item")
    assert_equal "menu-item", result["data-desktop-rails-bridge"]
  end

  def test_bridge_with_no_options
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    result = host.desktop_rails_bridge("notification")
    assert_equal({ "data-desktop-rails-bridge" => "notification" }, result)
  end

  def test_bridge_with_options
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    result = host.desktop_rails_bridge("menu-item", title: "Export PDF", shortcut: "Cmd+E")

    assert_equal "menu-item", result["data-desktop-rails-bridge"]
    assert_equal "Export PDF", result["data-desktop-rails-bridge-title"]
    assert_equal "Cmd+E", result["data-desktop-rails-bridge-shortcut"]
  end

  def test_bridge_converts_option_values_to_strings
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    result = host.desktop_rails_bridge("counter", count: 42, enabled: true)

    assert_equal "42", result["data-desktop-rails-bridge-count"]
    assert_equal "true", result["data-desktop-rails-bridge-enabled"]
  end

  def test_bridge_rejects_option_names_that_could_break_out_of_the_attribute
    host = ViewHelpersTestHost.new(DESKTOP_UA)

    error = assert_raises(ArgumentError) do
      host.desktop_rails_bridge("menu-item", 'title" onclick="alert(1)' => "x")
    end
    assert_match(/option name/, error.message)
  end

  def test_bridge_rejects_component_names_that_could_break_out_of_the_attribute
    host = ViewHelpersTestHost.new(DESKTOP_UA)

    assert_raises(ArgumentError) do
      host.desktop_rails_bridge('menu" onclick="alert(1)')
    end
  end

  def test_bridge_works_regardless_of_user_agent
    # Bridge helper does not depend on whether it is a desktop app
    host = ViewHelpersTestHost.new(BROWSER_UA)
    result = host.desktop_rails_bridge("menu-item", title: "Test")
    assert_equal "menu-item", result["data-desktop-rails-bridge"]
    assert_equal "Test", result["data-desktop-rails-bridge-title"]
  end

  # --- desktop_rails_only ---

  def test_desktop_only_renders_for_desktop
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    result = host.desktop_rails_only { "desktop content" }
    assert_equal "desktop content", result
  end

  def test_desktop_only_returns_nil_for_browser
    host = ViewHelpersTestHost.new(BROWSER_UA)
    result = host.desktop_rails_only { "desktop content" }
    assert_nil result
  end

  # --- turbo_web_only ---

  def test_web_only_renders_for_browser
    host = ViewHelpersTestHost.new(BROWSER_UA)
    result = host.turbo_web_only { "web content" }
    assert_equal "web content", result
  end

  def test_web_only_returns_nil_for_desktop
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    result = host.turbo_web_only { "web content" }
    assert_nil result
  end

  def test_inspector_predicate_reflects_config
    DesktopRails.configuration.inspector_enabled = true
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    assert host.desktop_rails_inspector?
  ensure
    DesktopRails.configuration.inspector_enabled = false
  end

  def test_inspector_meta_tag_present_when_enabled
    DesktopRails.configuration.inspector_enabled = true
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    assert_includes host.desktop_rails_inspector_meta_tag.to_s, "desktop-rails-inspector"
    assert_includes host.desktop_rails_inspector_meta_tag.to_s, "enabled"
    # carries the same-origin inspector URL (fallback path outside a mounted app)
    assert_includes host.desktop_rails_inspector_meta_tag.to_s, 'data-inspector-url="/desktop-rails/inspector.js"'
  ensure
    DesktopRails.configuration.inspector_enabled = false
  end

  def test_inspector_meta_tag_absent_when_disabled
    host = ViewHelpersTestHost.new(DESKTOP_UA)
    assert_nil host.desktop_rails_inspector_meta_tag
  end
end

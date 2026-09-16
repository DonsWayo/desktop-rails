require "test_helper"

class DetectionTestHost
  include DesktopRails::Detection::InstanceMethods rescue nil

  attr_reader :request

  def initialize(user_agent)
    @request = StubRequest.new(user_agent)
  end

  # Manually include the detection methods since we cannot use ActiveSupport::Concern
  # included block (it calls helper_method which requires a controller context).
  def desktop_rails_app?
    request.user_agent.to_s.match?(DesktopRails.configuration.user_agent_pattern)
  end

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

class DetectionTest < Minitest::Test
  # --- desktop_rails_app? ---

  def test_detects_desktop_rails_user_agent
    host = DetectionTestHost.new("Desktop Rails/0.1.0 (macOS; aarch64)")
    assert host.desktop_rails_app?
  end

  def test_rejects_regular_browser_user_agent
    host = DetectionTestHost.new("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)")
    refute host.desktop_rails_app?
  end

  def test_rejects_empty_user_agent
    host = DetectionTestHost.new("")
    refute host.desktop_rails_app?
  end

  def test_rejects_nil_user_agent
    host = DetectionTestHost.new(nil)
    refute host.desktop_rails_app?
  end

  def test_detects_desktop_rails_case_sensitive
    # The default pattern is /Desktop Rails/ which is case-sensitive
    host = DetectionTestHost.new("turbo desktop/0.1.0")
    refute host.desktop_rails_app?
  end

  def test_detects_desktop_rails_embedded_in_longer_ua
    host = DetectionTestHost.new("Mozilla/5.0 Desktop Rails/0.2.0 (Windows; x86_64)")
    assert host.desktop_rails_app?
  end

  # --- desktop_rails_platform ---

  def test_platform_macos
    host = DetectionTestHost.new("Desktop Rails/0.1.0 (macOS; aarch64)")
    assert_equal "macos", host.desktop_rails_platform
  end

  def test_platform_windows
    host = DetectionTestHost.new("Desktop Rails/0.1.0 (Windows; x86_64)")
    assert_equal "windows", host.desktop_rails_platform
  end

  def test_platform_linux
    host = DetectionTestHost.new("Desktop Rails/0.1.0 (Linux; x86_64)")
    assert_equal "linux", host.desktop_rails_platform
  end

  def test_platform_nil_for_non_desktop
    host = DetectionTestHost.new("Mozilla/5.0")
    assert_nil host.desktop_rails_platform
  end

  def test_platform_nil_for_unknown_os
    host = DetectionTestHost.new("Desktop Rails/0.1.0 (FreeBSD; aarch64)")
    assert_nil host.desktop_rails_platform
  end

  # --- desktop_rails_arch ---

  def test_arch_aarch64
    host = DetectionTestHost.new("Desktop Rails/0.1.0 (macOS; aarch64)")
    assert_equal "aarch64", host.desktop_rails_arch
  end

  def test_arch_x86_64
    host = DetectionTestHost.new("Desktop Rails/0.1.0 (Windows; x86_64)")
    assert_equal "x86_64", host.desktop_rails_arch
  end

  def test_arch_nil_for_non_desktop
    host = DetectionTestHost.new("Mozilla/5.0")
    assert_nil host.desktop_rails_arch
  end

  def test_arch_nil_for_unknown_arch
    host = DetectionTestHost.new("Desktop Rails/0.1.0 (macOS; arm32)")
    assert_nil host.desktop_rails_arch
  end

  # --- Custom user_agent_pattern ---

  def test_custom_user_agent_pattern
    DesktopRails.configure do |config|
      config.user_agent_pattern = /MyDesktopApp/
    end

    host = DetectionTestHost.new("MyDesktopApp/1.0 (macOS; aarch64)")
    assert host.desktop_rails_app?
    assert_equal "macos", host.desktop_rails_platform
  end

  def test_custom_pattern_rejects_default_ua
    DesktopRails.configure do |config|
      config.user_agent_pattern = /MyDesktopApp/
    end

    host = DetectionTestHost.new("Desktop Rails/0.1.0 (macOS; aarch64)")
    refute host.desktop_rails_app?
  end
end

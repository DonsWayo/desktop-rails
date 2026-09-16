require_relative "tooling_test_helper"
require "desktop_rails/tooling/windows_runtime"

class ToolingWindowsRuntimeTest < Minitest::Test
  include ToolingTestSupport

  WindowsRuntime = DesktopRails::Tooling::WindowsRuntime

  def test_the_portable_archive_url
    assert_equal "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-4.0.7-1/rubyinstaller-4.0.7-1-x64.7z",
                 WindowsRuntime.new(out: "C:/out").url
    assert_match(/RubyInstaller-3\.3\.9-1/, WindowsRuntime.new(out: "C:/out", version: "3.3.9").url)
  end

  def test_7z_extracts_into_the_named_directory_without_asking
    assert_equal [ "7z", "x", "C:/t/ruby.7z", "-oC:/t/unpacked", "-y" ],
                 WindowsRuntime.new(out: "C:/out").extract_argv("C:/t/ruby.7z", "C:/t/unpacked")
  end

  def test_fetch_unpacks_in_scratch_copies_into_place_and_verifies
    # A ruby.7z left in the current directory used to be packaged into the app
    # when desktop:runtime ran this from the app root.
    Dir.mktmpdir do |dir|
      out = File.join(dir, "app", ".desktop-rails", "runtime")
      write(File.join(out, "stale.txt"))
      runner = RecordingRunner.new
      runner.on(->(argv) { argv.first == "7z" }) do |argv|
        into = argv[3].delete_prefix("-o")
        executable(File.join(into, "rubyinstaller-4.0.7-1-x64", "bin", "ruby.exe"))
      end
      fetched = nil
      fetcher = ->(url, path) { fetched = path; write(path, "7z") }
      verified = []
      verification = Object.new
      verification.define_singleton_method(:verify!) { verified << File.exist?(File.join(out, "bin", "ruby.exe")) }

      WindowsRuntime.new(out: out, runner: runner, fetcher: fetcher, verification: verification, log: StringIO.new).fetch!

      assert File.exist?(File.join(out, "bin", "ruby.exe"))
      refute File.exist?(File.join(out, "stale.txt")), "an earlier runtime is replaced, not merged into"
      refute File.exist?(fetched), "the archive is removed with its scratch directory"
      refute_equal File.join(dir, "app"), File.dirname(fetched)
      assert_equal [ true ], verified
    end
  end

  def test_an_archive_with_nothing_inside_is_a_clear_failure
    Dir.mktmpdir do |dir|
      assert_raises(DesktopRails::Tooling::CheckFailed) { WindowsRuntime.unpacked_root(dir) }
    end
  end
end

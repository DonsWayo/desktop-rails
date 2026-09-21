require_relative "test_helper"
require "desktop_rails/packager/windows_gem_probe"
require "tmpdir"
require "fileutils"

# RubyInstaller's operating_system.rb created and deleted a file inside the
# packaged app's own interpreter on every launch, which the Windows GUI job saw
# as "Created ...\lib\ruby\lib\ruby\gems\3.4.0\writable_p". Packaging a
# Windows app now rewrites that probe in the copy it ships; that it is run on
# every Windows package is bundled_package_test.rb's.
class WindowsGemProbeTest < Minitest::Test
  WindowsGemProbe = DesktopRails::Packager::WindowsGemProbe

  # The start of the file as RubyInstaller 3.4 ships it, verbatim.
  RUBYINSTALLER = <<~'RUBY'
    require "ruby_installer/runtime"

    begin
      checkfile = File.join(Gem.default_dir, "/writable_p")
      File.write(checkfile, "")
      File.unlink(checkfile) rescue nil # Raises ENOENT sometimes
    rescue Errno::EACCES
      warn_per_user = true
      # Set default options for the bundle command
      ENV['GEM_HOME'] ||= Gem.user_dir
    rescue => err
      warn RubyInstaller::Runtime::Colors.yellow("Warning: Can't determine writability of default gem path: #{err}")
    end

    RubyInstaller::Runtime.enable_dll_search_paths
  RUBY

  def test_the_probe_is_replaced_by_the_answer_a_read_only_install_gets
    rewritten = WindowsGemProbe.rewrite(RUBYINSTALLER)

    refute_includes rewritten, "writable_p"
    refute_includes rewritten, "File.write"
    assert_includes rewritten, %(  raise Errno::EACCES, "a packaged app's interpreter is read-only"\n)
    assert_includes rewritten, "rescue Errno::EACCES"
    assert_includes rewritten, "RubyInstaller::Runtime.enable_dll_search_paths",
                    "the DLL search paths are what lets the interpreter load its own libraries"
  end

  # Taking the EACCES branch must leave a Ruby that parses and does what a
  # read-only install does, rather than a syntax error at every launch.
  def test_the_rewritten_block_runs_and_takes_the_read_only_branch
    block = WindowsGemProbe.rewrite(RUBYINSTALLER)[/^begin\n.*?^end\n/m]
    env = {}
    gem = Module.new { def self.user_dir = "C:/Users/someone/.local/share/gem" }

    Object.new.instance_exec(env, gem) do |env_, gem_|
      eval(block.gsub("ENV", "env_").gsub("Gem.", "gem_."), binding, __FILE__, __LINE__)
    end

    assert_equal "C:/Users/someone/.local/share/gem", env["GEM_HOME"]
  end

  def test_crlf_line_endings_are_kept
    rewritten = WindowsGemProbe.rewrite(RUBYINSTALLER.gsub("\n", "\r\n"))

    refute_includes rewritten, "writable_p"
    refute_match(/[^\r]\n/, rewritten, "a mix of line endings would be a second, quieter change")
  end

  def test_a_file_without_the_probe_is_left_alone
    assert_nil WindowsGemProbe.rewrite(%(require "ruby_installer/runtime"\n))
  end

  def test_a_probe_in_a_shape_it_does_not_know_stops_packaging
    changed = RUBYINSTALLER.sub(%(File.write(checkfile, "")), %(File.open(checkfile, "w") {}))

    assert_raises(DesktopRails::Packager::InvalidInput) { WindowsGemProbe.rewrite(changed) }
  end

  def test_it_rewrites_the_copy_where_rubyinstaller_puts_it
    Dir.mktmpdir do |runtime|
      file = File.join(runtime, "lib", "ruby", "3.4.0", "rubygems", "defaults", "operating_system.rb")
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, RUBYINSTALLER)

      assert_equal [ file ], WindowsGemProbe.apply(runtime)
      refute_includes File.read(file), "writable_p"
      assert_empty WindowsGemProbe.apply(runtime), "a second run has nothing left to do"
    end
  end
end

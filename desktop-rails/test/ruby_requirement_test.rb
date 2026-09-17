require_relative "test_helper"
require_relative "packaging_test"
require "desktop_rails/packager/ruby_requirement"
require "fileutils"
require "tmpdir"

# An app's Gemfile pins the developer's Ruby, and a packaged app runs the Ruby
# it carries. Bundler inside the package compares the two and refuses to load
# anything when they differ: "Your Ruby version is 4.0.7, but your Gemfile
# specified 4.0.6", at launch, on the user's machine. These hold the packed
# copy to accepting the runtime whenever only the patch release differs, and
# packaging to refusing, early and naming both, when it is more than that.
class RubyRequirementTest < Minitest::Test
  RubyRequirement = DesktopRails::Packager::RubyRequirement
  InvalidInput = DesktopRails::Packager::InvalidInput

  LOCK = <<~LOCK
    GEM
      remote: https://rubygems.org/
      specs:
        rack (3.2.7)

    DEPENDENCIES
      rack

    RUBY VERSION
       ruby 4.0.6p0

    BUNDLED WITH
       4.0.3
  LOCK

  def with_app(ruby_line, files: {})
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), <<~GEMFILE)
        source "https://rubygems.org"

        #{ruby_line}

        gem "rack"
        group :development, :test do
          gem "debug", platforms: %i[ mri windows ]
        end
      GEMFILE
      File.write(File.join(dir, "Gemfile.lock"), LOCK)
      files.each { |name, content| File.write(File.join(dir, name), content) }
      yield dir
    end
  end

  def apply(dir, runtime: "4.0.7", log: [])
    RubyRequirement.new(packed: dir, runtime_version: runtime, runtime_patchlevel: "0",
                        log: ->(message) { log << message }).apply!
  end

  def gemfile(dir)
    File.read(File.join(dir, "Gemfile"))
  end

  def test_an_exact_pin_to_another_patch_release_becomes_the_runtimes
    # What `rails new` writes for Rails 7.0 and 7.1.
    with_app(%(ruby "4.0.6")) do |dir|
      log = []
      apply(dir, log: log)
      assert_includes gemfile(dir), %(ruby "4.0.7"\n)
      assert_includes gemfile(dir), "# desktop-rails: was `ruby \"4.0.6\"`"
      refute_match(/^ruby "4\.0\.6"/, gemfile(dir))
      assert_includes File.read(File.join(dir, "Gemfile.lock")), "RUBY VERSION\n   ruby 4.0.7p0\n"
      assert_includes log.join("\n"), "was 4.0.6"
    end
  end

  def test_a_ruby_version_file_is_read_the_way_bundler_reads_it
    with_app(%(ruby file: ".ruby-version"), files: { ".ruby-version" => "ruby-4.0.5\n" }) do |dir|
      apply(dir)
      assert_includes gemfile(dir), %(ruby "4.0.7"\n)
      assert_equal "ruby-4.0.5\n", File.read(File.join(dir, ".ruby-version")), "only the Gemfile directive changes"
    end

    with_app(%(ruby File.read(".ruby-version").strip), files: { ".ruby-version" => "4.0.6\n" }) do |dir|
      apply(dir)
      assert_includes gemfile(dir), %(ruby "4.0.7"\n)
    end

    with_app(%(ruby file: ".tool-versions"), files: { ".tool-versions" => "nodejs 22.0.0\nruby 4.0.6\n" }) do |dir|
      apply(dir)
      assert_includes gemfile(dir), %(ruby "4.0.7"\n)
    end
  end

  def test_a_requirement_the_runtime_meets_is_left_as_written
    [ %(ruby ">= 3.2"), %(ruby "~> 4.0"), %(ruby "4.0.7"), %(ruby RUBY_VERSION), "" ].each do |line|
      with_app(line) do |dir|
        before = gemfile(dir)
        apply(dir)
        assert_equal before, gemfile(dir), line
        # The lock still records the Ruby that will read it.
        assert_includes File.read(File.join(dir, "Gemfile.lock")), "ruby 4.0.7p0", line
      end
    end
  end

  def test_a_patch_level_floor_above_the_runtime_is_loosened_to_its_series
    with_app(%(ruby ">= 4.0.9", "< 4.1")) do |dir|
      apply(dir)
      assert_includes gemfile(dir), %(ruby "4.0.7"\n)
    end
  end

  def test_a_requirement_the_runtime_cannot_meet_is_refused_naming_both_versions
    [ [ %(ruby "~> 3.4"), "~> 3.4" ], [ %(ruby "3.4.8"), "3.4.8" ], [ %(ruby "< 4"), "< 4" ],
      [ %(ruby ">= 4.1.0"), ">= 4.1.0" ] ].each do |line, described|
      with_app(line) do |dir|
        before = gemfile(dir)
        error = assert_raises(InvalidInput, line) { apply(dir) }
        assert_includes error.message, "requires Ruby #{described}"
        assert_includes error.message, "runtime being packaged is Ruby 4.0.7"
        assert_equal before, gemfile(dir), "nothing is rewritten when packaging is refused"
      end
    end
  end

  def test_another_engine_is_refused
    with_app(%(ruby "3.1.4", engine: "jruby", engine_version: "9.4.8.0")) do |dir|
      error = assert_raises(InvalidInput) { apply(dir, runtime: "3.1.4") }
      assert_includes error.message, "jruby 9.4.8.0"
    end
  end

  def test_a_gemfile_that_cannot_be_read_is_refused_rather_than_guessed
    with_app(%(ruby SomeConstantFromAGem::VERSION)) do |dir|
      error = assert_raises(InvalidInput) { apply(dir) }
      assert_match(/reading it failed/, error.message)
    end
  end

  def test_reading_the_gemfile_runs_no_gem_activation
    # Kernel#gem outside Bundler would activate the gem in this process.
    with_app(%(ruby "4.0.6")) do |dir|
      File.write(File.join(dir, "Gemfile"), gemfile(dir) + %(gem "definitely-not-installed-anywhere", "~> 99"\n))
      apply(dir)
      assert_includes gemfile(dir), %(ruby "4.0.7"\n)
    end
  end

  def test_a_directive_continued_onto_the_next_line_is_replaced_whole
    with_app(%(ruby ">= 4.0.8",\n     "< 5")) do |dir|
      apply(dir)
      assert_includes gemfile(dir), %(ruby "4.0.7"\n)
      refute_includes gemfile(dir), %(\n     "< 5"\n)
    end
  end
end

# desktop:gems installs with the runtime's Bundler, which refuses the same pin
# before it installs anything. The app's Gemfile is staged, repaired, under the
# build directory, and the developer's own files are left alone.
class GemsGemfileTest < Minitest::Test
  include PackagingSandbox

  def write_runtime_config(runtime, version)
    major, minor, teeny = version.split(".")
    dir = File.join(runtime, "lib", "ruby", "#{major}.#{minor}.0", "arm64-darwin")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "rbconfig.rb"),
               %(CONFIG["MAJOR"] = "#{major}"\nCONFIG["MINOR"] = "#{minor}"\nCONFIG["TEENY"] = "#{teeny}"\n) +
               %(CONFIG["PATCHLEVEL"] = "0"\nCONFIG["ruby_version"] = "#{major}.#{minor}.0"\n))
  end

  def test_the_apps_own_gemfile_when_the_runtime_meets_it
    with_sandbox do |paths|
      write_runtime_config(paths[:runtime], "4.0.7")
      File.write(File.join(paths[:app], "Gemfile"), %(source "https://rubygems.org"\nruby ">= 3.2"\ngem "rack"\n))
      assert_equal File.join(paths[:app], "Gemfile"), DesktopRails::Packaging.gems_gemfile!(log: ->(_) { })
    end
  end

  def test_a_staged_copy_when_only_the_patch_release_differs
    with_sandbox do |paths|
      write_runtime_config(paths[:runtime], "4.0.7")
      engine = File.join(paths[:root], "engine")
      FileUtils.mkdir_p(engine)
      File.write(File.join(engine, "engine.gemspec"), "")
      original = %(source "https://rubygems.org"\nruby "4.0.6"\ngem "engine", path: "../engine"\n)
      File.write(File.join(paths[:app], "Gemfile"), original)
      File.write(File.join(paths[:app], "Gemfile.lock"), "PATH\n  remote: ../engine\n  specs:\n    engine (0.1)\n")

      staged = DesktopRails::Packaging.gems_gemfile!(log: ->(_) { })
      assert_equal File.join(paths[:root], "build", "gemfile", "Gemfile"), staged
      assert_includes File.read(staged), %(ruby "4.0.7"\n)
      assert_includes File.read(staged), %(path: "vendor/path-gems/engine")
      assert File.exist?(File.join(File.dirname(staged), "vendor", "path-gems", "engine", "engine.gemspec"))
      assert_equal original, File.read(File.join(paths[:app], "Gemfile")), "the developer's Gemfile is never written"

      env, = DesktopRails::Packaging.gems_command(gemfile: staged)
      assert_equal staged, env["BUNDLE_GEMFILE"]
    end
  end

  def test_refused_before_installing_when_the_runtime_cannot_be_what_the_app_asks_for
    with_sandbox do |paths|
      write_runtime_config(paths[:runtime], "4.0.7")
      File.write(File.join(paths[:app], "Gemfile"), %(source "https://rubygems.org"\nruby "~> 3.4.0"\n))
      error = assert_raises(DesktopRails::Packager::InvalidInput) { DesktopRails::Packaging.gems_gemfile!(log: ->(_) { }) }
      assert_includes error.message, "4.0.7"
      assert_includes error.message, "~> 3.4.0"
    end
  end
end

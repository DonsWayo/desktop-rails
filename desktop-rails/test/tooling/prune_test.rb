require_relative "tooling_test_helper"
require "desktop_rails/tooling/prune"

# Which files pruning removes, against a tree shaped like a real bundle's
# Resources: the interpreter under ruby/, the app's gems under gems/.
class ToolingPruneTest < Minitest::Test
  include ToolingTestSupport

  Prune = DesktopRails::Tooling::Prune

  def with_bundle
    Dir.mktmpdir do |root|
      paths = {
        archive: write("#{root}/ruby/lib/libruby-static.a"),
        gem_cache: write("#{root}/gems/cache/rack-3.2.7.gem"),
        header: write("#{root}/ruby/include/ruby-3.4.0/ruby.h"),
        dsym: write("#{root}/ruby/bin/ruby.dSYM/Contents/Info.plist"),
        ri: write("#{root}/ruby/share/ri/3.4.0/system/String/cdesc-String.ri"),
        rdoc: write("#{root}/gems/doc/rack-3.2.7/rdoc/index.html"),
        gem_test: write("#{root}/gems/gems/rack-3.2.7/test/spec_request.rb"),
        gem_spec: write("#{root}/gems/gems/nokogiri-1.18/spec/helper.rb"),
        gem_features: write("#{root}/gems/gems/capybara-3/features/step.rb"),
        default_gem_test: write("#{root}/ruby/lib/ruby/gems/3.4.0/gems/minitest-5.25/test/minitest/test_a.rb"),
        # Library code that happens to be called test: rack-test's own lib.
        rack_test_lib: write("#{root}/gems/gems/rack-test-2.2/lib/rack/test/utils.rb"),
        app_test: write("#{root}/app/test/models/note_test.rb"),
        ruby: executable("#{root}/ruby/bin/ruby"),
        bundle: write("#{root}/ruby/lib/ruby/3.4.0/arm64-darwin/openssl.bundle"),
        dylib: write("#{root}/gems/gems/ffi-1/lib/libffi.dylib"),
        so: write("#{root}/gems/gems/sqlite3-2/lib/sqlite3_native.so"),
        bundle_in_test: write("#{root}/gems/gems/rack-3.2.7/test/fixture.bundle"),
        dll: write("#{root}/ruby/bin/ruby_builtin_dlls/libssl-3-x64.dll")
      }
      yield root, paths
    end
  end

  def test_removes_what_only_a_build_machine_reads
    with_bundle do |root, paths|
      plan = Prune.new(root, host_os: "darwin24").plan
      assert_equal [ paths[:archive] ], plan.static_archives
      assert_equal [ paths[:gem_cache] ], plan.gem_caches
      assert_equal [ "#{root}/ruby/include" ], plan.headers
      assert_equal [ "#{root}/ruby/bin/ruby.dSYM" ], plan.debug_symbols
      assert_equal [ "#{root}/gems/doc/rack-3.2.7/rdoc", "#{root}/ruby/share/ri" ], plan.docs.sort
    end
  end

  def test_gem_test_suites_only_at_each_gems_root
    # A bare `test` anywhere also matches rack-test's lib/rack/test/, which is
    # library code, and the app then fails to boot.
    with_bundle do |root, paths|
      plan = Prune.new(root, host_os: "darwin24").plan
      assert_equal [
        "#{root}/gems/gems/capybara-3/features",
        "#{root}/gems/gems/nokogiri-1.18/spec",
        "#{root}/gems/gems/rack-3.2.7/test",
        "#{root}/ruby/lib/ruby/gems/3.4.0/gems/minitest-5.25/test"
      ], plan.gem_test_suites.sort
      refute(plan.removals.any? { |path| paths[:rack_test_lib].start_with?(path) }, "rack-test's library must stay")
      refute(plan.removals.any? { |path| paths[:app_test].start_with?(path) }, "the app is not a gem")
    end
  end

  def test_any_ruby_abi_directory_counts_as_a_gem_root
    # The PowerShell copy hard-coded 3.4.0, so the next Ruby would have shipped
    # every default gem's tests on Windows alone.
    with_bundle do |root|
      suite = write("#{root}/ruby/lib/ruby/gems/3.5.0/gems/json-3/test/json_test.rb")
      assert_includes Prune.new(root, host_os: "mingw32").plan.gem_test_suites, File.dirname(suite)
    end
  end

  def test_keep_dev_keeps_docs_and_test_suites_but_not_build_leftovers
    with_bundle do |root|
      plan = Prune.new(root, keep_dev: true, host_os: "darwin24").plan
      assert_empty plan.docs
      assert_empty plan.gem_test_suites
      refute_empty plan.static_archives
      refute_empty plan.headers
    end
  end

  def test_strips_the_interpreter_and_loadable_binaries_that_survive
    with_bundle do |root, paths|
      plan = Prune.new(root, host_os: "darwin24").plan
      assert_equal [ paths[:dylib], paths[:bundle], paths[:ruby] ].sort, plan.strippable.sort
      refute_includes plan.strippable, paths[:bundle_in_test], "it is about to be deleted"
      assert_equal [ "strip", "-S", "-x", paths[:ruby] ], Prune.new(root).strip_argv(paths[:ruby])
    end
  end

  def test_nothing_is_stripped_on_windows
    with_bundle do |root|
      assert_empty Prune.new(root, host_os: "mingw32").plan.strippable
    end
  end

  def test_run_removes_the_plan_and_reports_the_saving
    with_bundle do |root, paths|
      runner = RecordingRunner.new
      log = StringIO.new
      Prune.new(root, host_os: "darwin24", runner: runner, log: log).run!

      %i[archive gem_cache header dsym ri rdoc gem_test gem_spec gem_features default_gem_test].each do |name|
        refute File.exist?(paths[name]), "#{name} should have been removed"
      end
      %i[rack_test_lib app_test ruby bundle dylib so dll].each do |name|
        assert File.exist?(paths[name]), "#{name} should have been kept"
      end
      if DesktopRails::Tooling.which("strip")
        assert_equal 3, runner.argvs.count { |argv| argv.first == "strip" }
      end
      assert_match(/total\s+\d+M -> \d+M/, log.string)
    end
  end

  def test_a_missing_directory_plans_nothing
    assert_empty Prune.new("/nonexistent/desktop-rails").plan.removals
  end
end

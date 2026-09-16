require_relative "test_helper"
require "rake"
require "turbo_desktop/packaging"

# The rake file is the thin layer over TurboDesktop::Packaging, so what is worth
# asserting here is that it loads, that it defines the three tasks the workflow
# promises, and that the engine is what puts them in a host app's Rakefile.
class DesktopRakeTasksTest < Minitest::Test
  RAKEFILE = File.expand_path("../lib/turbo_desktop/tasks/desktop.rake", __dir__)

  def setup
    super
    @rake = Rake::Application.new
    Rake.application = @rake
    # Rake only keeps a task's desc when it is asked to, which is what `rake -T`
    # does. Without this every comment reads back as nil.
    @recording = Rake::TaskManager.record_task_metadata
    Rake::TaskManager.record_task_metadata = true
    # load, not rake_require: the file is addressed by path here, and
    # rake_require resolves names against $LOAD_PATH.
    load RAKEFILE
  end

  def teardown
    Rake::TaskManager.record_task_metadata = @recording
    Rake.application = Rake::Application.new
    super
  end

  def test_defines_the_three_tasks_the_workflow_promises
    %w[desktop:runtime desktop:package desktop:run].each do |name|
      assert @rake.lookup(name), "#{name} was not defined"
    end
  end

  def test_every_task_is_described_so_rake_dash_t_lists_it
    # A task with no desc is invisible to `rake -T`, which is where a developer
    # who has not read the README will look for this workflow.
    %w[desktop:runtime desktop:package desktop:run].each do |name|
      refute_nil @rake.lookup(name).comment, "#{name} has no desc"
    end
  end

  def test_defines_no_methods_on_object
    # A .rake file's `def` lands on Object. These helpers are lambdas precisely
    # so they cannot collide with the host application's own code.
    refute Object.private_method_defined?(:with_clear_failures)
    refute Object.private_method_defined?(:run!)
  end

  def test_the_engine_loads_the_rake_file
    source = File.read(File.expand_path("../lib/turbo_desktop/engine.rb", __dir__))
    assert_match(/rake_tasks do/, source)
    assert_match(%r{tasks/desktop\.rake}, source)
    assert File.exist?(RAKEFILE), "the engine loads a file that must exist in the gem"
  end

  def test_the_rake_file_ships_in_the_gem
    # lib/**/* in the gemspec covers it, but a .rake file under lib is easy to
    # lose to a stray exclusion, and the failure would only show up for someone
    # who installed the released gem.
    files = Dir.chdir(File.expand_path("..", __dir__)) { Dir["lib/**/*"] }
    assert_includes files, "lib/turbo_desktop/tasks/desktop.rake"
  end

  def test_package_and_run_precompile_assets_first
    # Without this every asset 404s in the desktop environment: the page renders,
    # Turbo and Stimulus never boot, and forms do full page loads.
    %w[desktop:package desktop:run].each do |name|
      prerequisites = Rake::Task[name].prerequisites
      assert_includes prerequisites, "assets",
                      "#{name} must depend on desktop:assets, or the packaged app ships without CSS or JavaScript"
    end
    assert Rake::Task["desktop:assets"].comment, "desktop:assets needs a desc so rake -T lists it"
  end
end

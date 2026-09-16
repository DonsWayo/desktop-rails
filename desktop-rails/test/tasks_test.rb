require_relative "test_helper"
require "rake"
require "desktop_rails/packaging"

# The rake file is the thin layer over DesktopRails::Packaging, so what is worth
# asserting here is that it loads, that it defines the three tasks the workflow
# promises, and that the engine is what puts them in a host app's Rakefile.
class DesktopRakeTasksTest < Minitest::Test
  RAKEFILE = File.expand_path("../lib/desktop_rails/tasks/desktop.rake", __dir__)

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
    %w[desktop:runtime desktop:shell desktop:package desktop:run].each do |name|
      assert @rake.lookup(name), "#{name} was not defined"
    end
  end

  def test_every_task_is_described_so_rake_dash_t_lists_it
    # A task with no desc is invisible to `rake -T`, which is where a developer
    # who has not read the README will look for this workflow.
    %w[desktop:runtime desktop:shell desktop:package desktop:run].each do |name|
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
    source = File.read(File.expand_path("../lib/desktop_rails/engine.rb", __dir__))
    assert_match(/rake_tasks do/, source)
    assert_match(%r{tasks/desktop\.rake}, source)
    assert File.exist?(RAKEFILE), "the engine loads a file that must exist in the gem"
  end

  def test_the_rake_file_ships_in_the_gem
    # lib/**/* in the gemspec covers it, but a .rake file under lib is easy to
    # lose to a stray exclusion, and the failure would only show up for someone
    # who installed the released gem.
    files = Dir.chdir(File.expand_path("..", __dir__)) { Dir["lib/**/*"] }
    assert_includes files, "lib/desktop_rails/tasks/desktop.rake"
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

  def test_package_obtains_a_shell_first
    # Without a shell the package is a server with no window. desktop:shell is
    # a no-op when one is already configured, so depending on it costs nothing
    # and makes a window the default. First, so a failed download stops the
    # task before the slow asset and gem work rather than after it.
    prerequisites = Rake::Task["desktop:package"].prerequisites
    assert_equal "shell", prerequisites.first
  end

  def test_download_failures_are_messages_not_backtraces
    source = File.read(RAKEFILE)
    assert_match(/rescue DesktopRails::Packaging::MissingPrerequisite, DesktopRails::Packaging::DownloadFailed/, source)
  end

  def test_only_an_unpublished_release_falls_back_to_building_the_runtime
    # A checksum mismatch that quietly turned into a forty-minute compile would
    # hide exactly the thing the checksum exists to surface.
    source = File.read(RAKEFILE)
    runtime_task = source[/task :runtime do.*?\n  end\n/m]
    assert_match(/rescue DesktopRails::Packaging::NotPublished/, runtime_task)
    refute_match(/rescue DesktopRails::Packaging::DownloadFailed/, runtime_task)
    refute_match(/rescue StandardError/, runtime_task)
  end
end

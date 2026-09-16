require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "active_record/version"

# A packaged app on a fresh machine used to open onto an empty SQLite file:
# nothing created or migrated the schema, so the first page that touched a
# model returned 500. It only ever worked where a developer had migrated the
# data directory by hand.
#
# Each test boots a real, minimal Rails app in a child process — the way the
# boot script does — against real SQLite files, because loading a schema,
# running migrations and seeding are exactly what a stub would get wrong, and
# one process can only ever boot one Rails application.
class DatabasePrepareTest < Minitest::Test
  def setup
    super
    begin
      require "sqlite3"
    rescue LoadError
      skip "sqlite3 is not installed"
    end
    @tmp = Dir.mktmpdir
    @app = File.join(@tmp, "app")
    @data = File.join(@tmp, "data")
    build_app
  end

  def teardown
    FileUtils.chmod_R("u+w", @tmp) if @tmp
    FileUtils.rm_rf(@tmp) if @tmp
    super
  end

  def test_a_new_database_gets_the_schema_file_and_the_seeds
    result, stdout = boot!

    assert_equal "prepared", result["result"]
    assert_includes result["primary_tables"], "notes"
    # Loaded from db/schema.rb, not by replaying migrations: only the schema
    # file has this column.
    assert_includes result["note_columns"], "from_schema"
    assert_equal 1, result["seeded"], "seeds should run once, on the database they created"
    assert_equal "", stdout, "stdout carries the handshake; nothing else may be written there"
  end

  def test_every_configured_database_is_prepared_not_just_the_primary
    # The Rails 8 layout: solid_cache, solid_queue and solid_cable each have a
    # database and a schema file of their own.
    result, = boot!
    assert_includes result["cache_tables"], "solid_cache_entries"
    assert File.exist?(File.join(@data, "app_cache.sqlite3"))
  end

  def test_an_update_runs_pending_migrations_and_keeps_the_data
    boot!
    write(File.join(@app, "db", "migrate", "20990101000000_add_pinned_to_notes.rb"), <<~RUBY)
      class AddPinnedToNotes < ActiveRecord::Migration[#{migration_version}]
        def change
          add_column :notes, :pinned, :boolean
        end
      end
    RUBY

    result, stdout = boot!
    assert_includes result["note_columns"], "pinned", "the pending migration did not run"
    assert_equal 1, result["seeded"], "seeds ran again on an existing database, or the data was lost"
    assert_equal "", stdout
  end

  def test_works_with_a_read_only_application_tree
    # A signed bundle cannot be written to. Dumping the schema after migrating
    # is the usual way that goes wrong.
    boot!
    write(File.join(@app, "db", "migrate", "20990101000000_add_pinned_to_notes.rb"), <<~RUBY)
      class AddPinnedToNotes < ActiveRecord::Migration[#{migration_version}]
        def change
          add_column :notes, :pinned, :boolean
        end
      end
    RUBY
    schema_before = File.read(File.join(@app, "db", "schema.rb"))
    FileUtils.chmod_R("a-w", @app)

    result, = boot!
    assert_includes result["note_columns"], "pinned"
    assert_equal schema_before, File.read(File.join(@app, "db", "schema.rb"))
  end

  def test_two_copies_starting_at_once_both_boot
    runs = %w[first second].map { |name| Thread.new { run_app(result: "#{name}.json") } }.map(&:value)
    runs.each do |output, status, _|
      assert status.success?, "a concurrent start failed:\n#{output}"
    end
    %w[first second].each do |name|
      result = JSON.parse(File.read(File.join(@tmp, "#{name}.json")))
      assert_equal 1, result["seeded"], "both copies loaded the schema and seeded"
    end
  end

  def test_turned_off_it_does_nothing
    DesktopRails.configuration.prepare_database = false
    assert_equal :skipped, DesktopRails::Database.prepare!(data_dir: @data)
    refute File.exist?(File.join(@data, DesktopRails::Database::LOCK_FILE))
  end

  private

  def migration_version
    ActiveRecord::VERSION::STRING[/\A\d+\.\d+/]
  end

  def write(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def build_app
    write(File.join(@app, "config", "database.yml"), <<~YAML)
      desktop:
        primary:
          adapter: sqlite3
          timeout: 5000
          database: <%= File.join(ENV.fetch("DESKTOP_DATA_DIR"), "app.sqlite3") %>
        cache:
          adapter: sqlite3
          timeout: 5000
          database: <%= File.join(ENV.fetch("DESKTOP_DATA_DIR"), "app_cache.sqlite3") %>
          migrations_paths: db/cache_migrate
    YAML

    write(File.join(@app, "db", "schema.rb"), <<~RUBY)
      ActiveRecord::Schema[#{migration_version}].define(version: 2026_01_01_000000) do
        create_table :notes do |t|
          t.string :title
          t.string :from_schema
        end
      end
    RUBY
    write(File.join(@app, "db", "migrate", "20260101000000_create_notes.rb"), <<~RUBY)
      class CreateNotes < ActiveRecord::Migration[#{migration_version}]
        def change
          create_table(:notes) { |t| t.string :title }
        end
      end
    RUBY
    write(File.join(@app, "db", "cache_schema.rb"), <<~RUBY)
      ActiveRecord::Schema[#{migration_version}].define(version: 1) do
        create_table :solid_cache_entries do |t|
          t.binary :key
        end
      end
    RUBY
    write(File.join(@app, "db", "seeds.rb"), <<~RUBY)
      ActiveRecord::Base.connection.execute("INSERT INTO notes (title) VALUES ('seeded')")
    RUBY

    write(File.join(@app, "boot.rb"), <<~RUBY)
      require "rails"
      require "active_record/railtie"
      require "desktop_rails"
      require "json"

      class MiniApp < Rails::Application
        config.root = __dir__
        config.eager_load = false
        config.logger = Logger.new(nil)
        config.secret_key_base = "x" * 64
        config.active_support.deprecation = :silence
      end
      Rails.application.initialize!

      result = DesktopRails::Database.prepare!

      primary = ActiveRecord::Base.connection
      cache = ActiveRecord::Base.establish_connection(:cache) && ActiveRecord::Base.connection
      cache_tables = cache.tables
      ActiveRecord::Base.establish_connection(:primary)
      primary = ActiveRecord::Base.connection

      File.write(ENV.fetch("RESULT"), JSON.generate(
        result: result,
        primary_tables: primary.tables,
        cache_tables: cache_tables,
        note_columns: primary.columns(:notes).map(&:name),
        seeded: primary.select_value("SELECT COUNT(*) FROM notes WHERE title = 'seeded'")
      ))
    RUBY
  end

  def run_app(result: "result.json")
    env = {
      "RAILS_ENV" => "desktop",
      "DESKTOP_DATA_DIR" => @data,
      "RESULT" => File.join(@tmp, result)
    }
    Open3.capture3(env, RbConfig.ruby, File.join(@app, "boot.rb"), chdir: @tmp)
      .then { |stdout, stderr, status| [ "#{stdout}#{stderr}", status, stdout ] }
  end

  def boot!
    output, status, stdout = run_app
    assert status.success?, "the app failed to boot:\n#{output}"
    [ JSON.parse(File.read(File.join(@tmp, "result.json"))), stdout ]
  end
end

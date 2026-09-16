# frozen_string_literal: true

require "fileutils"

module DesktopRails
  # Bring every database of the running environment up to date, before the
  # server accepts a request.
  #
  # A server app is migrated by whoever deploys it. A desktop app is deployed by
  # someone double-clicking it on a machine nobody administers, so its schema
  # has to arrive with it: on first launch the data directory holds nothing, and
  # after an update it holds last version's schema. Without this every packaged
  # app opened on a fresh machine onto an empty SQLite file, and the first page
  # that touched a model returned 500.
  #
  # The semantics are `db:prepare`'s, because they are the right ones and Rails
  # already implements them: create a missing database and load its schema file
  # (db/schema.rb, db/cache_schema.rb, ...), run pending migrations on an
  # existing one, seed a database that was just created. Every database the
  # environment configures is covered, including the Rails 8 cache, queue and
  # cable databases.
  #
  # Called by bin/desktop-boot and the packaged boot.rb after the application
  # has loaded and before Puma binds.
  module Database
    LOCK_FILE = "database.lock"

    module_function

    # Returns :prepared, or :skipped when there is nothing to do: no Active
    # Record, no database configured for this environment, or preparation
    # turned off in the configuration.
    #
    # Everything this prints goes to `out` (stderr by default). Active Record's
    # tasks write to $stdout, and a packaged app's stdout carries the handshake
    # line the shell is waiting for, so nothing else may ever reach it.
    def prepare!(data_dir: nil, out: $stderr)
      return :skipped unless DesktopRails.configuration.prepare_database
      return :skipped unless defined?(::ActiveRecord::Base) && defined?(::Rails) && ::Rails.application
      return :skipped if ::ActiveRecord::Base.configurations.configs_for(env_name: ::Rails.env).empty?

      require "active_record/tasks/database_tasks"
      tasks = ::ActiveRecord::Tasks::DatabaseTasks

      with_lock(data_dir || DesktopRails.data_dir(create: true)) do
        quietly_to(out) do
          # Dumping the schema after migrating would write db/schema.rb inside
          # the bundle, which is read-only and code-signed. The shipped schema
          # file is the one the app was built with, and it stays that way.
          dump_was = ::ActiveRecord.dump_schema_after_migration
          ::ActiveRecord.dump_schema_after_migration = false
          begin
            tasks.prepare_all
          ensure
            ::ActiveRecord.dump_schema_after_migration = dump_was
          end
        end
      end

      # Models loaded while the app eager loaded may have cached columns from
      # before the schema existed.
      ::ActiveRecord::Base.descendants.each do |model|
        model.reset_column_information unless model.abstract_class?
      end
      :prepared
    end

    # Two copies of the app starting at once — a double-click that registered
    # twice, or a login item racing the user — would otherwise both see a
    # missing database and both try to load the schema into it. The second
    # waits, then finds nothing left to do.
    def with_lock(dir)
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir.to_s, LOCK_FILE), File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end

    def quietly_to(out)
      stdout_was = $stdout
      $stdout = out
      yield
    ensure
      $stdout = stdout_was
    end
  end
end

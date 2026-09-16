require "rails/generators/base"
require "yaml"

module DesktopRails
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Install Desktop Rails into your Rails application"

      class_option :desktop_env, type: :boolean, default: true,
                   desc: "Generate config/environments/desktop.rb and bin/desktop-boot"

      # A class method so the tests can stub it: they cannot swap the json gem
      # under a running process.
      def self.active_support_decodes_json?
        require "active_support/json"
        ActiveSupport::JSON.decode("{}")
        true
      rescue ArgumentError
        false
      end

      def initialize(*)
        super
        @notes = []
      end

      def copy_initializer
        template "initializer.rb.tt", "config/initializers/desktop_rails.rb"
      end

      def mount_engine
        route 'mount DesktopRails::Engine => "/desktop-rails"'
      end

      # The environment a packaged app runs in. Not production: the bundle is
      # read-only, the server is on loopback, and a forking job supervisor would
      # outlive the window. See the template for the reasoning on each setting.
      def create_desktop_environment
        return unless options[:desktop_env]

        template "desktop.rb.tt", "config/environments/desktop.rb"
      end

      # What the shell spawns, and what `rails desktop:run` spawns, so the two
      # cannot drift apart.
      def create_boot_script
        return unless options[:desktop_env]

        template "desktop-boot.tt", "bin/desktop-boot"
        chmod "bin/desktop-boot", 0o755, verbose: false
      end

      # Rails only has configuration for the environments it generated, so a new
      # environment needs its own section in each file keyed by one. This used to
      # be left to the user with a one-line instruction, and skipping it failed
      # at boot with Rails' "The `desktop` database is not configured", which
      # never mentions this gem. Everything needed to write the section is known
      # here.
      #
      # SQLite only, in the data directory: a desktop app has no database server
      # to connect to. Any other adapter gets a note rather than a guess.
      def configure_database
        return unless options[:desktop_env]

        path = "config/database.yml"
        source = read_destination(path)
        if source.nil?
          @notes << "There is no config/database.yml, so no desktop database was configured."
          return
        end
        return if environment_defined?(source, "desktop")

        layout = DatabaseLayout.parse(source)
        if layout.nil?
          @notes << "config/database.yml could not be read without running it, so no desktop " \
                    "database was configured. Add a `desktop:` section with an sqlite3 database " \
                    "under DesktopRails.data_dir."
        elsif !layout.sqlite?
          @notes << "config/database.yml uses #{layout.adapters.join(", ")}. A desktop app has no " \
                    "database server to reach, so no desktop database was configured. Add a " \
                    "`desktop:` section by hand; sqlite3 under DesktopRails.data_dir is what a " \
                    "packaged app can always write to."
        else
          append_to_file path, layout.desktop_section
        end
      end

      # Broadcasts stay in process: a desktop app is one Puma process with one
      # user, and the solid_cable or redis adapters a new app is generated with
      # would each need a database or a server of their own.
      def configure_action_cable
        return unless options[:desktop_env]

        path = "config/cable.yml"
        source = read_destination(path)
        return if source.nil? || environment_defined?(source, "desktop")

        append_to_file path, <<~YAML

          # Written by desktop_rails:install. One process and one user, so
          # broadcasts stay in memory rather than needing a database or a server.
          desktop:
            adapter: async
        YAML
      end

      # Uploads go to the data directory for the same reason the database does.
      # The desktop environment selects this service whenever storage.yml
      # exists, so the two are written together.
      def configure_active_storage
        return unless options[:desktop_env]

        path = "config/storage.yml"
        source = read_destination(path)
        return if source.nil? || environment_defined?(source, "desktop")

        append_to_file path, <<~YAML

          # Written by desktop_rails:install. The packaged app is read-only, so
          # uploads live in the per-user data directory, beside the database.
          desktop:
            service: Disk
            root: <%= DesktopRails.data_dir.join("storage") %>
        YAML
      end

      # .desktop-rails/ holds the interpreter, the gems and every build. None of
      # it is source, and the interpreter alone is a hundred megabytes.
      def ignore_build_directory
        path = ".gitignore"
        source = read_destination(path)
        return if source.nil? || source.match?(%r{^/?\.desktop-rails/?$})

        append_to_file path, "\n# The runtime, gems and builds of bin/rails desktop:package\n/.desktop-rails/\n"
      end

      # json 3 dropped the positional options hash that ActiveSupport::JSON.decode
      # still passes in Rails 8.1.3.1, so decoding raises ArgumentError — and
      # with it every signed cookie, which means every form POST returns 500.
      # Not a bug in this gem, but it is in every app generated while the two
      # disagree, and a desktop app is exactly where nobody sees the stack trace.
      #
      # Decided by calling the real thing in the app being installed into, so the
      # pin is only written while the combination is actually broken.
      def pin_json_when_active_support_cannot_decode
        return if self.class.active_support_decodes_json?

        path = "Gemfile"
        source = read_destination(path)
        return if source.nil? || source.match?(/^\s*gem\s+["']json["']/)

        append_to_file path, <<~RUBY

          # Added by desktop_rails:install. json 3 removed the positional options
          # hash that ActiveSupport::JSON.decode still passes, so decoding raises
          # ArgumentError and every signed cookie, so every form POST, fails.
          # Remove this once Active Support and json agree again.
          gem "json", "< 3"
        RUBY
        @notes << "json was pinned below 3 in the Gemfile, because ActiveSupport::JSON.decode " \
                  "cannot use the installed version. Run `bundle install`."
      end

      def show_next_steps
        say ""
        say "Desktop Rails installed!", :green
        say ""
        @notes.each do |note|
          say "Note: #{note}", :yellow
          say ""
        end
        say "To develop:"
        say "  1. npx desktop-rails init      # scaffold the desktop shell"
        say "  2. rails server                # start your Rails app"
        say "  3. npx desktop-rails dev       # launch the desktop app"
        say ""
        say "To ship:"
        say "  1. bin/rails desktop:runtime   # fetch or build a relocatable Ruby, once"
        say "  2. bin/rails desktop:run       # boot the app the way a bundle will"
        say "  3. bin/rails desktop:package   # build the app for this platform"
        say ""
      end

      private

      def read_destination(path)
        full = File.join(destination_root, path)
        File.exist?(full) ? File.read(full) : nil
      end

      def environment_defined?(source, name)
        source.match?(/^#{Regexp.escape(name)}:/)
      end


      # What config/database.yml configures, read without evaluating its ERB:
      # the generator runs before the app has booted, and a template that calls
      # into the app would fail here for reasons unrelated to the layout.
      class DatabaseLayout
        # Keys carried over from the reference environment. Anything else — a
        # host, a pool size computed in ERB — either comes from the shared default
        # or means nothing for a file in the data directory.
        CARRIED_KEYS = %w[migrations_paths schema_dump database_tasks replica seeds].freeze

        def self.parse(source)
          data = YAML.safe_load(source.gsub(/<%.*?%>/m, "erb"), aliases: true)
          return nil unless data.is_a?(Hash)

          # The environment a packaged app replaces is production; an app that
          # has none is described by development.
          reference = data["production"] || data["development"]
          return nil unless reference.is_a?(Hash)

          anchor = source[/^default:\s*&(\w+)/, 1]
          anchor = nil unless data["default"].is_a?(Hash) && data["default"]["adapter"] == "sqlite3"

          if reference.key?("adapter") || reference.key?("database") || reference.key?("url")
            new({ "primary" => reference }, single: true, anchor: anchor)
          elsif !reference.empty? && reference.values.all?(Hash)
            new(reference, single: false, anchor: anchor)
          end
        rescue Psych::Exception
          nil
        end

        def initialize(entries, single:, anchor:)
          @entries = entries
          @single = single
          @anchor = anchor
        end

        def adapters
          @entries.values.map { |config| config["adapter"] || "a url with no adapter" }.uniq
        end

        def sqlite?
          @entries.values.all? { |config| config["adapter"] == "sqlite3" }
        end

        def desktop_section
          lines = [
            "",
            "# Written by desktop_rails:install. A packaged app is read-only, so every",
            "# database lives in the per-user data directory: Application Support on",
            "# macOS, %LOCALAPPDATA% on Windows, $XDG_DATA_HOME on Linux. The app creates,",
            "# loads and migrates them as it starts; see DesktopRails::Database.",
            "desktop:"
          ]
          if @single
            lines.concat(entry_lines("primary", @entries["primary"], "  "))
          else
            @entries.each do |name, config|
              lines << "  #{name}:"
              lines.concat(entry_lines(name, config, "    "))
            end
          end
          lines.join("\n") + "\n"
        end

        private

        def entry_lines(name, config, indent)
          lines = if @anchor
            [ "#{indent}<<: *#{@anchor}" ]
          else
            [ "#{indent}adapter: sqlite3", "#{indent}timeout: 5000" ]
          end
          file = name == "primary" ? "app.sqlite3" : "app_#{name}.sqlite3"
          # Not data_dir(create: true): database.yml is evaluated in every
          # environment, and development has no business creating the packaged
          # app's directory. SQLite creates the file's directory itself.
          lines << "#{indent}database: <%= DesktopRails.data_dir.join(#{file.inspect}) %>"
          CARRIED_KEYS.each do |key|
            value = config[key]
            next if value.nil? || value == "erb"

            lines << "#{indent}#{key}: #{value.is_a?(Array) ? value.inspect : value}"
          end
          lines
        end
      end
    end
  end
end

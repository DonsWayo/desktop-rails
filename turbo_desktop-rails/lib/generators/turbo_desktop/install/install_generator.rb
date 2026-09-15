require "rails/generators/base"

module TurboDesktop
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Install Turbo Desktop into your Rails application"

      class_option :desktop_env, type: :boolean, default: true,
                   desc: "Generate config/environments/desktop.rb and bin/desktop-boot"

      def copy_initializer
        template "initializer.rb.tt", "config/initializers/turbo_desktop.rb"
      end

      def mount_engine
        route 'mount TurboDesktop::Engine => "/turbo-desktop"'
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

      # Rails only writes a key into config/database.yml, config/storage.yml and
      # friends for environments it knows about. Nothing here edits those — an
      # app's database layout is its own business — but silence would make the
      # first `rails desktop:run` fail with a message about a missing adapter
      # rather than about the thing that is actually missing.
      def show_next_steps
        say ""
        say "Turbo Desktop installed!", :green
        say ""
        if options[:desktop_env]
          say "A desktop environment was generated. Add a `desktop:` section to"
          say "config/database.yml (and storage.yml, if you use Active Storage);"
          say "point it at TurboDesktop.data_dir so the app can write to it."
          say ""
        end
        say "To develop:"
        say "  1. npx turbo-desktop init      # scaffold the desktop shell"
        say "  2. rails server                # start your Rails app"
        say "  3. npx turbo-desktop dev       # launch the desktop app"
        say ""
        say "To ship:"
        say "  1. bin/rails desktop:runtime   # fetch or build a relocatable Ruby, once"
        say "  2. bin/rails desktop:run       # boot the app the way a bundle will"
        say "  3. bin/rails desktop:package   # build the app for this platform"
        say ""
      end
    end
  end
end

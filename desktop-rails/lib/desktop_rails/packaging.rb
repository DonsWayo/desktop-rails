# frozen_string_literal: true

require "json"
require "pathname"
require "shellwords"
require "desktop_rails/paths"

module DesktopRails
  # The Rails side of packaging.
  #
  # The shell scripts under packaging/ are the implementation and stay the
  # implementation: they encode measured facts about relocatable interpreters,
  # entitlements and inside-out signing, and reimplementing any of that in Ruby
  # would mean two things to keep correct. This module only answers the
  # questions a Rails app can answer better than a shell script — where the app
  # is, what it is called, which packer this platform wants — and builds argv.
  #
  # Nothing here runs a command. `package_command` and friends return argv
  # arrays, so the decisions can be tested without a compiler, a runtime or a
  # code-signing identity on the machine; the rake tasks are the thin layer that
  # executes them.
  module Packaging
    # Raised when something the packers need is absent. The message always says
    # what was looked for and what to do about it, because the alternative is a
    # developer staring at "No such file or directory".
    class MissingPrerequisite < StandardError; end

    module_function

    def platform
      Paths.platform
    end

    # ─── Locating the packaging scripts ──────────────────────────────────────

    # The gem cannot ship packaging/: those scripts live at the root of the
    # desktop_rails repository, above this gem's own directory, and RubyGems
    # will not package files from outside a gem root. So they are located
    # instead, and when they cannot be found the error says how to point at them.
    def packaging_dir
      candidates = packaging_candidates
      found = candidates.find { |dir| File.exist?(File.join(dir, "pack.sh")) }
      return Pathname.new(found) if found

      raise MissingPrerequisite, <<~MSG
        Could not find the desktop_rails packaging scripts.

        Looked in:
        #{candidates.map { |c| "  #{c}" }.join("\n")}

        They live in the desktop_rails repository, not in this gem — RubyGems
        cannot package files from above a gem's own root. Clone it, then point
        at the directory with an environment variable:

          DESKTOP_RAILS_PACKAGING=/path/to/desktop_rails/packaging bin/rails desktop:package

        or in config/initializers/desktop_rails.rb:

          config.packaging_dir = "/path/to/desktop_rails/packaging"
      MSG
    end

    def packaging_candidates
      [
        Paths.presence(ENV["DESKTOP_RAILS_PACKAGING"]),
        Paths.presence(DesktopRails.configuration.packaging_dir)&.to_s,
        # A checkout of this repository, with the gem in desktop-rails/.
        File.expand_path("../../../packaging", __dir__),
        # A Rails app sitting inside, or beside, a checkout.
        (app_root && File.expand_path("packaging", app_root.to_s)),
        (app_root && File.expand_path("../desktop_rails/packaging", app_root.to_s))
      ].compact
    end

    def script(name)
      path = packaging_dir.join(name)
      unless path.exist?
        raise MissingPrerequisite,
              "#{path} does not exist — the packaging directory at #{packaging_dir} looks incomplete."
      end
      path
    end

    # ─── What is being packaged ──────────────────────────────────────────────

    def app_root
      return Pathname.new(ENV["DESKTOP_RAILS_APP"]) if Paths.presence(ENV["DESKTOP_RAILS_APP"])
      return Rails.root if defined?(Rails) && Rails.respond_to?(:root) && Rails.root

      nil
    end

    def app_root!
      root = app_root
      unless root && File.exist?(File.join(root.to_s, "config.ru"))
        raise MissingPrerequisite, <<~MSG
          #{root || "The current directory"} has no config.ru, so there is no Rails app to package.

          Run this from a Rails application, or point at one:

            DESKTOP_RAILS_APP=/path/to/app bin/rails desktop:package
        MSG
      end
      Pathname.new(root)
    end

    # Where build products that are neither source nor Rails' own tmp/ belong.
    # Not tmp/, because `rails tmp:clear` would throw away an interpreter that
    # took twenty minutes to compile.
    def build_dir
      Pathname.new(Paths.presence(ENV["DESKTOP_RAILS_BUILD"]) ||
                   File.join((app_root || Dir.pwd).to_s, ".desktop-rails"))
    end

    def dist_dir
      Paths.presence(ENV["DESKTOP_RAILS_DIST"]) ||
        Paths.presence(DesktopRails.configuration.dist_dir)&.to_s ||
        build_dir.join("dist").to_s
    end

    # ─── The interpreter ─────────────────────────────────────────────────────

    def runtime_candidates
      [
        Paths.presence(ENV["DESKTOP_RAILS_RUNTIME"]),
        Paths.presence(DesktopRails.configuration.runtime_dir)&.to_s,
        gem_runtime_path,
        build_dir.join("runtime").to_s
      ].compact
    end

    # desktop-rails-runtime ships a prebuilt interpreter per platform. When it
    # is installed there is nothing to build, which is the difference between a
    # twenty-minute first package and a one-minute one.
    def gem_runtime_path
      return nil unless defined?(DesktopRails::Runtime)

      DesktopRails::Runtime.available? ? DesktopRails::Runtime.path : nil
    rescue StandardError
      nil
    end

    def runtime_dir
      runtime_candidates.find { |dir| runtime?(dir) }
    end

    def runtime?(dir)
      return false unless dir

      %w[ruby ruby.exe].any? { |exe| File.executable?(File.join(dir.to_s, "bin", exe)) }
    end

    def runtime_dir!
      runtime_dir || raise(MissingPrerequisite, <<~MSG)
        No relocatable Ruby to package.

        Looked for bin/ruby in:
        #{runtime_candidates.map { |c| "  #{c}" }.join("\n")}

        Build one — it takes a while, and it is reused afterwards:

          bin/rails desktop:runtime

        or install the prebuilt interpreter for this platform:

          bundle add desktop-rails-runtime
      MSG
    end

    # ─── argv ────────────────────────────────────────────────────────────────

    # Build the interpreter, or fetch it on Windows, where RubyInstaller already
    # publishes a portable archive that relocates and building would be work for
    # its own sake.
    def runtime_command(out: nil)
      out ||= build_dir.join("runtime")
      if platform == :windows
        [ "pwsh", "-File", script("fetch-windows-runtime.ps1").to_s, "-Out", out.to_s ]
      else
        [ script("build-runtime.sh").to_s, "--out", out.to_s ]
      end
    end

    def package_command(name: nil, app_id: nil, app: nil, runtime: nil, gems: nil,
                        shell: nil, out: nil, identity: nil)
      name    ||= DesktopRails.app_name
      app_id  ||= DesktopRails.app_id
      app     ||= app_root!.to_s
      runtime ||= runtime_dir!.to_s
      out     ||= dist_dir
      gems    ||= gems_dir!
      shell   ||= shell_binary

      case platform
      when :macos
        argv = [ script("pack.sh").to_s, "--app", app, "--runtime", runtime,
                 "--name", name, "--bundle-id", app_id, "--out", out.to_s ]
        argv += [ "--gems", gems.to_s ] if gems
        argv += [ "--shell", shell.to_s ] if shell
        identity ||= DesktopRails.configuration.signing_identity
        argv += [ "--identity", identity.to_s ] if identity
        argv
      when :linux
        argv = [ script("pack-linux.sh").to_s, "--app", app, "--runtime", runtime,
                 "--name", name, "--app-id", app_id, "--out", out.to_s ]
        argv += [ "--gems", gems.to_s ] if gems
        argv
      else
        argv = [ "pwsh", "-File", script("pack-windows.ps1").to_s, "-App", app,
                 "-Runtime", runtime, "-Name", name, "-AppId", app_id, "-Out", out.to_s ]
        argv += [ "-Gems", gems.to_s ] if gems
        argv
      end
    end

    # The app's own gems, so the bundle does not depend on the developer's
    # GEM_HOME. Only passed when the directory is really there: --gems is
    # optional and the packers skip a missing one silently, which would hide the
    # mistake until the bundle failed to boot on somebody else's machine.
    def gems_dir
      [
        Paths.presence(ENV["DESKTOP_RAILS_GEMS"]),
        Paths.presence(DesktopRails.configuration.gems_dir)&.to_s,
        bundled_gems_dir.to_s,
        (app_root && File.join(app_root.to_s, "vendor", "bundle"))
      ].compact.find { |dir| File.directory?(dir) && !Dir.empty?(dir) }
    end

    # Where desktop:gems installs the app's gems for the interpreter that ships.
    def bundled_gems_dir
      build_dir.join("gems")
    end

    # The gems a packaged app needs, built by the interpreter it will run on.
    #
    # Not the development Ruby's gem path: native extensions (sqlite3, puma,
    # nio4r, bigdecimal) compile against the interpreter that installs them, and
    # the development Ruby links a package manager's libraries that the bundle
    # does not carry. So the shipped interpreter installs its own set.
    #
    # GEM_HOME rather than BUNDLE_PATH, because BUNDLE_PATH nests gems under
    # ruby/<abi>/ and the launchers expect them flat.
    def gems_command
      runtime = runtime_dir!
      root = app_root!
      env = {
        "GEM_HOME" => bundled_gems_dir.to_s,
        "GEM_PATH" => bundled_gems_dir.to_s,
        "BUNDLE_GEMFILE" => File.join(root.to_s, "Gemfile"),
        "BUNDLE_WITHOUT" => "development:test",
        "BUNDLE_PATH" => nil,
        "PATH" => [ File.join(runtime.to_s, "bin"), ENV["PATH"] ].join(File::PATH_SEPARATOR)
      }
      [ env, File.join(runtime.to_s, "bin", "bundle"), "install" ]
    end

    # A bundle with no gems cannot boot, and packaging one anyway reports success
    # and "signature verifies" over an app that dies on `require "rack"`.
    def gems_dir!
      gems_dir || raise(MissingPrerequisite, <<~MSG)
        No gems to package, so the app could not start.

        Install them for the interpreter that ships:

          bin/rails desktop:gems

        or point at an existing set with DESKTOP_RAILS_GEMS.
      MSG
    end

    # The Tauri shell. Without one the packers still produce a bundle, but it is
    # a server with no window — useful for testing the packaging, not something
    # to hand a person.
    def shell_binary
      [
        Paths.presence(ENV["DESKTOP_RAILS_SHELL"]),
        Paths.presence(DesktopRails.configuration.shell_binary)&.to_s,
        shell_binary_in_checkout
      ].compact.find { |bin| File.file?(bin) && File.executable?(bin) }
    end

    def shell_binary_in_checkout
      exe = platform == :windows ? "desktop-rails.exe" : "desktop-rails"
      packaging_dir.dirname.join("src-tauri", "target", "release", exe).to_s
    rescue MissingPrerequisite
      nil
    end

    # ─── Running the app the way a bundle will ───────────────────────────────

    def boot_script
      root = app_root!
      [ root.join("bin", "desktop-boot"), root.join("boot.rb") ].find(&:exist?) ||
        raise(MissingPrerequisite, <<~MSG)
          No bin/desktop-boot in #{root}.

          It is what a packaged app runs, and what desktop:run runs so that the
          two cannot drift. Generate it:

            bin/rails generate desktop_rails:install
        MSG
    end

    # The one line a parent must write to the child's stdin before the app
    # finishes booting.
    #
    # The engine reads exactly one line from stdin during initialization, and
    # that read blocks. A parent that holds stdin open — which it must, because
    # closing it is how the app is told to exit — but never writes deadlocks the
    # child before Puma binds: the app waits for a line that is not coming, and
    # the parent waits for a port that will never be announced.
    #
    # desktop:run is not the shell and has no control channel to offer, so it
    # says exactly that, in the shape the engine knows how to dismiss.
    def no_shell_handshake
      JSON.generate(protocol: "1.0", control: nil, token: nil)
    end

    def to_shell(argv)
      argv.map { |arg| Shellwords.escape(arg.to_s) }.join(" ")
    end
  end
end

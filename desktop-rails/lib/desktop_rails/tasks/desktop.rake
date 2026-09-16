require "fileutils"
# frozen_string_literal: true

# The Rails-native packaging workflow.
#
#   bin/rails desktop:runtime   # get a relocatable interpreter, once
#   bin/rails desktop:package   # build the bundle for this platform
#   bin/rails desktop:run       # boot the app exactly as the bundle will
#
# Each task shells out to the scripts under packaging/ rather than
# reimplementing them. See DesktopRails::Packaging for why, and for where the
# scripts are looked for.

require "desktop_rails/packaging"

# Lambdas rather than `def`, which inside a .rake file would define methods on
# Object and collide with whatever else the application has loaded.

# Rake turns any exception into a backtrace, which buries the one sentence a
# developer needs. A missing prerequisite is a message, not a crash.
with_clear_failures = lambda do |&block|
  block.call
rescue DesktopRails::Packaging::MissingPrerequisite => e
  abort "\n#{e.message}"
end

run = lambda do |argv|
  puts "==> #{DesktopRails::Packaging.to_shell(argv)}"
  # No shell in between: argv reaches execve as it is, so a path with a space in
  # it — "~/Library/Application Support/..." on every Mac — cannot split.
  #
  # And outside this process's bundle. bin/rails runs with Bundler loaded, and
  # its RUBYOPT=-rbundler/setup and BUNDLE_* variables are inherited by every
  # script launched from here — including any Ruby those scripts start, which
  # then tries to set up this app's bundle with the wrong interpreter and fails
  # with GemNotFound. The packaging scripts are standalone and must see a clean
  # environment.
  launch = -> { system(*argv.map(&:to_s)) }
  ok = defined?(Bundler) ? Bundler.with_unbundled_env(&launch) : launch.call
  abort "\n#{argv.first} failed (exit #{$?&.exitstatus})." unless ok
end

namespace :desktop do
  desc "Fetch or build the relocatable Ruby a packaged app ships"
  task :runtime do
    with_clear_failures.call do
      packaging = DesktopRails::Packaging

      if (existing = packaging.runtime_dir)
        puts "A relocatable Ruby is already here: #{existing}"
        puts "Delete it, or set DESKTOP_RAILS_RUNTIME elsewhere, to build another."
        next
      end

      out = packaging.build_dir.join("runtime")
      if packaging.platform == :windows
        puts "Fetching RubyInstaller's portable archive into #{out}"
      else
        puts "Building a relocatable Ruby into #{out}."
        puts "This compiles OpenSSL, libyaml and Ruby itself, so it takes a while."
        puts "`bundle add desktop-rails-runtime` installs a prebuilt one instead."
      end
      run.call(packaging.runtime_command(out: out))
      puts "\nRuntime ready: #{out}"
    end
  end

  desc "Install this app's gems for the interpreter a packaged app ships"
  task :gems do
    with_clear_failures.call do
      packaging = DesktopRails::Packaging
      env, *argv = packaging.gems_command
      puts "Installing gems for the packaged interpreter"
      puts "  runtime: #{packaging.runtime_dir!}"
      puts "  into:    #{packaging.bundled_gems_dir}"
      FileUtils.mkdir_p(packaging.bundled_gems_dir)
      # A clean environment, not just an extra one. bin/rails starts with Bundler
      # loaded, which sets RUBYOPT=-rbundler/setup and BUNDLE_* variables; a
      # child `bundle install` inherits them and resolves against the parent's
      # already-installed gems — "Could not find rails-8.1.3.1 in locally
      # installed gems", reported from the development Ruby's Bundler even
      # though a different interpreter was asked to run. stdin from the null
      # device: see desktop:assets.
      run_clean = -> { system(env, *argv, chdir: packaging.app_root!.to_s, in: File::NULL) }
      ok = defined?(Bundler) ? Bundler.with_unbundled_env(&run_clean) : run_clean.call
      abort "bundle install failed for the packaged interpreter; its output is above." unless ok
    end
  end

  desc "Precompile assets for the desktop environment, which serves them from public/"
  task :assets do
    with_clear_failures.call do
      root = DesktopRails::Packaging.app_root!

      # The desktop environment serves precompiled files and never compiles at
      # request time. Without this, every asset 404s: the page renders, but Turbo
      # and Stimulus never boot, and a form submit does a full page load. That is
      # how every app built with this gem shipped until this task existed.
      unless File.exist?(File.join(root, "config", "importmap.rb")) ||
             File.exist?(File.join(root, "app", "assets"))
        puts "No asset pipeline in #{root}; skipping precompile."
        next
      end

      puts "Precompiling assets for the desktop environment"
      # Shelled out rather than invoked in-process: Rake::Task#invoke would
      # compile for whatever environment this rake process booted in, not
      # desktop. stdin comes from the null device because a Rails process in the
      # desktop environment must never wait on a stdin nobody will write to.
      ok = system({ "RAILS_ENV" => "desktop" },
                  File.join(root, "bin", "rails"), "assets:precompile",
                  chdir: root, in: File::NULL)
      abort "assets:precompile failed in the desktop environment; its output is above." unless ok
    end
  end

  desc "Package this Rails app for the current platform"
  task package: %i[assets gems] do
    with_clear_failures.call do
      packaging = DesktopRails::Packaging
      argv = packaging.package_command

      puts "Packaging #{DesktopRails.app_name} (#{DesktopRails.app_id}) for #{packaging.platform}"
      puts "  app:     #{packaging.app_root!}"
      puts "  runtime: #{packaging.runtime_dir!}"
      puts "  gems:    #{packaging.gems_dir || "(none — the bundle will use the runtime's own)"}"
      puts "  shell:   #{packaging.shell_binary || "(none — the bundle will have no window)"}"
      puts "  out:     #{packaging.dist_dir}"
      run.call(argv)
    end
  end

  desc "Boot this app the way a packaged bundle does, and print the URL"
  task run: :assets do
    with_clear_failures.call do
      packaging = DesktopRails::Packaging
      root = packaging.app_root!
      script = packaging.boot_script

      # The bundle's launcher exports these, so desktop:run exports them too.
      # The point of this task is that a failure here is a failure there.
      env = {
        "RAILS_ENV" => ENV["RAILS_ENV"] || "desktop",
        "DESKTOP_DATA_DIR" => ENV["DESKTOP_DATA_DIR"] || DesktopRails.data_dir(create: true).to_s
      }

      puts "Booting #{DesktopRails.app_name} in the #{env["RAILS_ENV"]} environment"
      puts "  data:  #{env["DESKTOP_DATA_DIR"]}"
      puts "  boot:  #{script}"

      # Hold the child's stdin open and read its first stdout line, which is
      # what the shell does. Closing stdin is how a packaged app is told to
      # exit — the only signal that survives the shell being force-quit — so
      # driving it any other way would test something nobody ships.
      require "open3"
      require "json"
      Open3.popen2(env, RbConfig.ruby, script.to_s, chdir: root.to_s) do |stdin, stdout, thread|
        stdin.sync = true

        # One line of handshake, first, and before anything is read back. The
        # engine blocks on this read while the app boots; see
        # DesktopRails::Packaging.no_shell_handshake for what deadlocks without
        # it.
        stdin.puts packaging.no_shell_handshake

        handshake = stdout.gets
        if handshake.nil?
          abort "\nThe app exited without announcing itself. Its output is above."
        end

        begin
          url = JSON.parse(handshake)["url"]
          puts "\nListening at #{url}"
        rescue JSON::ParserError
          puts "\nThe app's first line of output was not a handshake: #{handshake.strip}"
        end
        puts "Ctrl-C to stop.\n\n"

        trap("INT") { stdin.close rescue nil }
        thread.join
      end
    end
  end
end

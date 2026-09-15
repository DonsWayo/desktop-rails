# frozen_string_literal: true

# The Rails-native packaging workflow.
#
#   bin/rails desktop:runtime   # get a relocatable interpreter, once
#   bin/rails desktop:package   # build the bundle for this platform
#   bin/rails desktop:run       # boot the app exactly as the bundle will
#
# Each task shells out to the scripts under packaging/ rather than
# reimplementing them. See TurboDesktop::Packaging for why, and for where the
# scripts are looked for.

require "turbo_desktop/packaging"

# Lambdas rather than `def`, which inside a .rake file would define methods on
# Object and collide with whatever else the application has loaded.

# Rake turns any exception into a backtrace, which buries the one sentence a
# developer needs. A missing prerequisite is a message, not a crash.
with_clear_failures = lambda do |&block|
  block.call
rescue TurboDesktop::Packaging::MissingPrerequisite => e
  abort "\n#{e.message}"
end

run = lambda do |argv|
  puts "==> #{TurboDesktop::Packaging.to_shell(argv)}"
  # No shell in between: argv reaches execve as it is, so a path with a space in
  # it — "~/Library/Application Support/..." on every Mac — cannot split.
  abort "\n#{argv.first} failed (exit #{$?&.exitstatus})." unless system(*argv.map(&:to_s))
end

namespace :desktop do
  desc "Fetch or build the relocatable Ruby a packaged app ships"
  task :runtime do
    with_clear_failures.call do
      packaging = TurboDesktop::Packaging

      if (existing = packaging.runtime_dir)
        puts "A relocatable Ruby is already here: #{existing}"
        puts "Delete it, or set TURBO_DESKTOP_RUNTIME elsewhere, to build another."
        next
      end

      out = packaging.build_dir.join("runtime")
      if packaging.platform == :windows
        puts "Fetching RubyInstaller's portable archive into #{out}"
      else
        puts "Building a relocatable Ruby into #{out}."
        puts "This compiles OpenSSL, libyaml and Ruby itself, so it takes a while."
        puts "`bundle add turbo_desktop-runtime` installs a prebuilt one instead."
      end
      run.call(packaging.runtime_command(out: out))
      puts "\nRuntime ready: #{out}"
    end
  end

  desc "Package this Rails app for the current platform"
  task :package do
    with_clear_failures.call do
      packaging = TurboDesktop::Packaging
      argv = packaging.package_command

      puts "Packaging #{TurboDesktop.app_name} (#{TurboDesktop.app_id}) for #{packaging.platform}"
      puts "  app:     #{packaging.app_root!}"
      puts "  runtime: #{packaging.runtime_dir!}"
      puts "  gems:    #{packaging.gems_dir || "(none — the bundle will use the runtime's own)"}"
      puts "  shell:   #{packaging.shell_binary || "(none — the bundle will have no window)"}"
      puts "  out:     #{packaging.dist_dir}"
      run.call(argv)
    end
  end

  desc "Boot this app the way a packaged bundle does, and print the URL"
  task :run do
    with_clear_failures.call do
      packaging = TurboDesktop::Packaging
      root = packaging.app_root!
      script = packaging.boot_script

      # The bundle's launcher exports these, so desktop:run exports them too.
      # The point of this task is that a failure here is a failure there.
      env = {
        "RAILS_ENV" => ENV["RAILS_ENV"] || "desktop",
        "DESKTOP_DATA_DIR" => ENV["DESKTOP_DATA_DIR"] || TurboDesktop.data_dir(create: true).to_s
      }

      puts "Booting #{TurboDesktop.app_name} in the #{env["RAILS_ENV"]} environment"
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
        # TurboDesktop::Packaging.no_shell_handshake for what deadlocks without
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

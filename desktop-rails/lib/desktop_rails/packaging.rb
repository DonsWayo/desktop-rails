# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "rbconfig"
require "shellwords"
require "uri"
require "desktop_rails/configuration"
require "desktop_rails/paths"
require "desktop_rails/version"

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

    # A download that went wrong in a way retrying or reporting can fix: a bad
    # checksum, a network failure, a server error. Never silently replaced by a
    # build from source, because the build would hide the problem.
    class DownloadFailed < StandardError; end

    # The release, or this platform's asset in it, does not exist. The one
    # download failure that does fall back to building, since there is nothing
    # to download.
    class NotPublished < StandardError; end

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

    # A desktop-rails-runtime gem, built locally with packaging/gem.sh, carries
    # an interpreter. It is not published anywhere — desktop:runtime downloads
    # the same interpreter from a GitHub release instead — but a gem somebody
    # built and installed is still honoured rather than ignored.
    def gem_runtime_path
      return nil unless defined?(DesktopRails::Runtime)

      DesktopRails::Runtime.available? ? DesktopRails::Runtime.path : nil
    rescue StandardError
      nil
    end

    def runtime_dir
      runtime_candidates.find { |dir| runtime?(dir) }
    end

    # Where desktop:runtime puts a new interpreter. DESKTOP_RAILS_RUNTIME names
    # where the runtime is looked for first, so it is also where one is built:
    # building into .desktop-rails/ while the variable points elsewhere left a
    # CI cache, or a runtime shared between apps, permanently empty.
    def runtime_build_dir
      Pathname.new(Paths.presence(ENV["DESKTOP_RAILS_RUNTIME"]) || build_dir.join("runtime").to_s)
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

        Download the prebuilt one for this platform, or build it where none is
        published. Either way it is reused afterwards:

          bin/rails desktop:runtime

        or point at an interpreter you already have:

          DESKTOP_RAILS_RUNTIME=/path/to/ruby bin/rails desktop:package
      MSG
    end

    # ─── argv ────────────────────────────────────────────────────────────────

    # Build the interpreter, or fetch it on Windows, where RubyInstaller already
    # publishes a portable archive that relocates and building would be work for
    # its own sake.
    def runtime_command(out: nil)
      out ||= runtime_build_dir
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
        argv += [ "--shell", shell.to_s ] if shell
        argv
      else
        argv = [ "pwsh", "-File", script("pack-windows.ps1").to_s, "-App", app,
                 "-Runtime", runtime, "-Name", name, "-AppId", app_id, "-Out", out.to_s ]
        argv += [ "-Gems", gems.to_s ] if gems
        argv += [ "-Shell", shell.to_s ] if shell
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
    #
    # Bundler is run as a script by the shipped interpreter rather than executed
    # directly. bin/bundle is a Ruby script with no extension, which Windows
    # cannot execute at all, and on Unix its shebang names whatever path the
    # interpreter was built at rather than where it sits now.
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
      [ env, ruby_in(runtime), File.join(runtime.to_s, "bin", "bundle"), "install" ]
    end

    def ruby_in(runtime)
      exe = File.join(runtime.to_s, "bin", "ruby.exe")
      File.exist?(exe) ? exe : File.join(runtime.to_s, "bin", "ruby")
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
    #
    # An explicit choice wins, then a shell built in a checkout, because someone
    # running cargo there is working on the shell and wants that build. The
    # downloaded one comes last: it is the default for everybody else.
    def shell_binary
      shell_candidates.find { |bin| File.file?(bin) && File.executable?(bin) }
    end

    def shell_candidates
      [
        Paths.presence(ENV["DESKTOP_RAILS_SHELL"]),
        Paths.presence(DesktopRails.configuration.shell_binary)&.to_s,
        shell_binary_in_checkout,
        downloaded_shell_path.to_s
      ].compact
    end

    def shell_executable_name(on = platform)
      on == :windows ? "desktop-rails.exe" : "desktop-rails"
    end

    def shell_binary_in_checkout
      packaging_dir.dirname.join("src-tauri", "target", "release", shell_executable_name).to_s
    rescue MissingPrerequisite
      nil
    end

    # Under the version, because the shell and the gem speak a handshake to each
    # other: upgrading the gem should fetch the shell that matches it, not keep
    # finding the one downloaded for the previous release.
    def downloaded_shell_path(version: release_version)
      build_dir.join("shell", version.to_s, shell_executable_name)
    end

    # Building the shell from source means cargo in a checkout of this
    # repository, which is also what a gem installed from GitHub sits inside.
    # --manifest-path rather than a chdir, so the argv is the whole story, and
    # the output still lands in src-tauri/target/release where
    # shell_binary_in_checkout looks.
    def shell_build_command(env: ENV)
      manifest = begin
        packaging_dir.dirname.join("src-tauri", "Cargo.toml")
      rescue MissingPrerequisite
        nil
      end

      unless manifest&.exist?
        raise MissingPrerequisite, <<~MSG
          DESKTOP_RAILS_SHELL_FROM_SOURCE is set, but there is no src-tauri/Cargo.toml
          beside the packaging scripts to build from.

          Building the shell needs a checkout of the desktop-rails repository. Unset
          DESKTOP_RAILS_SHELL_FROM_SOURCE to download the prebuilt shell instead.
        MSG
      end

      cargo = executable_on_path("cargo", env: env)
      unless cargo
        raise MissingPrerequisite, <<~MSG
          DESKTOP_RAILS_SHELL_FROM_SOURCE is set, but cargo is not on PATH.

          Install Rust (https://rustup.rs), or unset DESKTOP_RAILS_SHELL_FROM_SOURCE
          to download the prebuilt shell instead.
        MSG
      end

      [ cargo, "build", "--release", "--manifest-path", manifest.to_s ]
    end

    def executable_on_path(name, env: ENV)
      extensions = platform == :windows ? [ ".exe", ".cmd", ".bat", "" ] : [ "" ]
      env["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        extensions.each do |ext|
          candidate = File.join(dir, "#{name}#{ext}")
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
      end
      nil
    end

    # ─── Prebuilt runtimes and shells ────────────────────────────────────────
    #
    # Each release of this repository publishes, per platform, the relocatable
    # interpreter and the shell binary, with a SHA256SUMS file beside them. The
    # URLs are computed rather than discovered — no API call, no token, no rate
    # limit — so everything below is a function of a version and a platform, and
    # .github/workflows/release-prebuilt.yml calls these same functions to name
    # what it uploads. The gem and the release cannot disagree about a name.
    #
    # DesktopRails::Prebuilt does the downloading; nothing here touches the
    # network.

    RELEASE_REPOSITORY = "DonsWayo/desktop-rails"
    DEFAULT_RELEASE_URL = "https://github.com/#{RELEASE_REPOSITORY}/releases/download".freeze
    CHECKSUMS_ASSET = "SHA256SUMS"

    # The platforms a release carries, named the way RubyGems names them.
    RELEASE_TRIPLES = %w[arm64-darwin x86_64-darwin x86_64-linux x64-mingw-ucrt].freeze

    # The directory at the top of every runtime archive. The release workflow
    # archives out/ruby, and extraction expects exactly this.
    RUNTIME_ARCHIVE_ROOT = "ruby"

    # The gem version is the release: gem 0.3.0.pre1 downloads from tag
    # v0.3.0.pre1. Written down as a function because every download URL is
    # computed from it, and a tag that does not follow it is a release no
    # installed gem can find. The release workflow refuses such a tag.
    def release_tag(version)
      "v#{version}"
    end

    # The same version in the form Cargo and npm require. RubyGems writes a
    # prerelease as 0.3.0.pre1; SemVer needs 0.3.0-pre.1. The release workflow
    # refuses to publish when Cargo.toml or package.json disagree with this,
    # because the shell reports its crate version to the updater.
    def semver(version)
      major, minor, patch, *rest = Gem::Version.new(version.to_s).segments
      core = [ major, minor || 0, patch || 0 ].join(".")
      rest.empty? ? core : "#{core}-#{rest.join(".")}"
    end

    def prerelease?(version)
      Gem::Version.new(version.to_s).prerelease?
    end

    def release_version(env: ENV)
      Paths.presence(env["DESKTOP_RAILS_RELEASE_VERSION"]) ||
        Paths.presence(DesktopRails.configuration.release_version)&.to_s ||
        DesktopRails::VERSION
    end

    # Overridable so a mirror, or a fork's own releases, can stand in. The tag
    # and the asset name are still appended, so a mirror keeps the same layout.
    def release_base_url(env: ENV)
      (Paths.presence(env["DESKTOP_RAILS_RELEASE_URL"]) ||
        Paths.presence(DesktopRails.configuration.release_url)&.to_s ||
        DEFAULT_RELEASE_URL).chomp("/")
    end

    # Which published platform this machine is, or nil when none is published
    # for it. nil is an answer, not an error: it is what sends desktop:runtime
    # to build from source.
    #
    # Musl Linux is nil on purpose. The published Linux interpreter links glibc
    # and would fail to start with an error that names neither.
    def release_triple(host_os: RbConfig::CONFIG["host_os"], host_cpu: RbConfig::CONFIG["host_cpu"])
      os = host_os.to_s
      cpu = host_cpu.to_s
      if os.match?(/darwin/i)
        return "arm64-darwin" if cpu.match?(/\A(arm64|aarch64)\z/)
        return "x86_64-darwin" if cpu == "x86_64"
      elsif os.match?(/mingw|mswin/i)
        return "x64-mingw-ucrt" if cpu.match?(/\A(x64|x86_64)\z/)
      elsif os.match?(/linux/i) && !os.match?(/musl/i)
        return "x86_64-linux" if cpu == "x86_64"
      end
      nil
    end

    def windows_triple?(triple)
      triple.to_s.include?("mingw")
    end

    # A zip on Windows because Windows opens one with nothing installed; a
    # tarball elsewhere because it keeps the executable bits.
    def runtime_asset_name(version:, triple:)
      "desktop-rails-runtime-#{version}-#{triple}.#{windows_triple?(triple) ? "zip" : "tar.gz"}"
    end

    # The bare executable, not an archive: it is one file, and downloading it
    # is the whole installation.
    def shell_asset_name(version:, triple:)
      "desktop-rails-shell-#{version}-#{triple}#{windows_triple?(triple) ? ".exe" : ""}"
    end

    # Every file a release must carry: what the workflow checks before it
    # publishes, and what a mirror has to provide.
    def release_asset_names(version:)
      RELEASE_TRIPLES.flat_map do |triple|
        [ runtime_asset_name(version: version, triple: triple),
          shell_asset_name(version: version, triple: triple) ]
      end + [ CHECKSUMS_ASSET ]
    end

    def release_asset_url(name, version:, base_url: DEFAULT_RELEASE_URL)
      "#{base_url.to_s.chomp("/")}/#{release_tag(version)}/#{name}"
    end

    # GitHub answers a release download with a redirect to a signed URL on
    # another host. The Location is absolute there, but it is resolved against
    # the request anyway, because a mirror is entitled to send a relative one.
    #
    # A redirect from https to http is refused: SHA256SUMS travels the same way
    # as the asset it vouches for, so a downgrade would let both be replaced.
    def redirect_target(from, location)
      target = URI.join(from.to_s, location.to_s)
      if URI(from.to_s).scheme == "https" && target.scheme != "https"
        raise DownloadFailed, "#{from} redirected to #{target}, which is not https; refusing to follow it."
      end

      target.to_s
    end

    # sha256sum's own format, "<hex>  <name>", with "*" before the name when
    # written in binary mode. Other lines are skipped rather than fatal, so a
    # comment cannot break every install.
    def parse_checksums(text)
      text.to_s.each_line.with_object({}) do |line, sums|
        match = line.strip.match(/\A(\h{64})\s+\*?(.+)\z/)
        sums[match[2].strip] = match[1].downcase if match
      end
    end

    # A release whose SHA256SUMS has no line for an asset does not carry that
    # asset, as far as installing goes: there is nothing to verify it against.
    def expected_checksum!(sums, name)
      sums.fetch(name) do
        raise NotPublished, "#{CHECKSUMS_ASSET} lists no #{name}, so the release does not carry it."
      end
    end

    def verify_checksum!(path, expected, name: File.basename(path.to_s))
      actual = Digest::SHA256.file(path.to_s).hexdigest
      return actual if actual == expected.to_s.downcase

      raise DownloadFailed, <<~MSG
        #{name} does not match #{CHECKSUMS_ASSET}, so it was not installed.

          expected #{expected}
          got      #{actual}

        A truncated or altered download looks exactly like this. Run the task
        again; if it keeps happening, the release itself is wrong.
      MSG
    end

    # argv that unpacks a runtime archive into a directory. tar on macOS and
    # Linux, which keeps the executable bits an interpreter needs. On Windows,
    # Expand-Archive with both paths as single-quoted PowerShell literals — the
    # one quoting in which a backslash and a space are just characters.
    def extract_command(archive, into:, triple:)
      if windows_triple?(triple)
        [ "pwsh", "-NoProfile", "-NonInteractive", "-Command",
          "$ErrorActionPreference = 'Stop'; " \
          "Expand-Archive -LiteralPath #{powershell_literal(archive)} " \
          "-DestinationPath #{powershell_literal(into)} -Force" ]
      else
        [ "tar", "-xzf", archive.to_s, "-C", into.to_s ]
      end
    end

    def powershell_literal(value)
      "'#{value.to_s.gsub("'", "''")}'"
    end

    # What proves a downloaded interpreter works on this machine. On macOS and
    # Linux that is verify-runtime.sh, the check every build passes in CI
    # before it is published. Windows has no such script, so the interpreter is
    # asked the questions fetch-windows-runtime.ps1 asks.
    def runtime_check_command(dir, triple: release_triple)
      if windows_triple?(triple)
        [ File.join(dir.to_s, "bin", "ruby.exe"), "-e", WINDOWS_RUNTIME_CHECK ]
      else
        [ script("verify-runtime.sh").to_s, dir.to_s ]
      end
    end

    WINDOWS_RUNTIME_CHECK = <<~'RUBY'
      require "psych"
      require "openssl"
      abort "psych broken" unless Psych.load("- 1") == [1]
      abort "openssl mismatch" unless OpenSSL::OPENSSL_VERSION == OpenSSL::OPENSSL_LIBRARY_VERSION
      prefix = File.expand_path(RbConfig::CONFIG["prefix"])
      abort "RbConfig points at #{prefix}, not the extracted interpreter" unless File.expand_path(RbConfig.ruby).start_with?(prefix)
      puts "OK  ruby #{RUBY_VERSION} #{RUBY_PLATFORM}, psych #{Psych::VERSION}, #{OpenSSL::OPENSSL_VERSION}"
    RUBY

    # Opting out of downloads. Unset, empty, "0", "false", "no" and "off" all
    # mean no, because a variable set to "false" that meant yes would be a trap.
    def from_source?(variable, env: ENV)
      value = Paths.presence(env[variable])
      return false unless value

      !%w[0 false no off].include?(value.strip.downcase)
    end

    def runtime_from_source?(env: ENV)
      from_source?("DESKTOP_RAILS_RUNTIME_FROM_SOURCE", env: env)
    end

    def shell_from_source?(env: ENV)
      from_source?("DESKTOP_RAILS_SHELL_FROM_SOURCE", env: env)
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

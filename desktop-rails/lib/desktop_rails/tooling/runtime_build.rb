# frozen_string_literal: true

require "etc"
require "fileutils"
require "desktop_rails/tooling"

module DesktopRails
  module Tooling
    # Builds a Ruby that can be moved, for shipping inside an app bundle.
    #
    # A package-manager Ruby cannot be shipped. On macOS libruby links gmp,
    # openssl.bundle links libssl, and stdlib psych.bundle links libyaml, all by
    # absolute path; Rails will not boot without psych, so copying an existing
    # interpreter fails on any path. Linux has the same problem with a distro
    # Ruby.
    #
    # So the interpreter is built for the job: --enable-load-relative makes it
    # resolve its own lib/ and encodings relative to the binary, and libyaml and
    # OpenSSL are compiled statically from source into a vendor prefix so nothing
    # points outside the bundle.
    #
    # Windows is not built here. RubyInstaller already ships a portable archive
    # that relocates correctly; see WindowsRuntime.
    #
    # Any Ruby that can run this gem drives the build. It only runs configure and
    # make; the interpreter it produces is compiled from source and shares nothing
    # with the one running this code.
    class RuntimeBuild
      # The versions a release ships. Bumping one means a new vendor cache key in
      # the workflows that build runtimes, which name the OpenSSL version in it.
      DEFAULT_RUBY_VERSION = "4.0.7"
      DEFAULT_OPENSSL_VERSION = "4.0.2"
      DEFAULT_YAML_VERSION = "0.2.5"

      # The directory layout CI caches: `vendor` is keyed on the dependency
      # versions, so it must stay where the workflows look for it.
      attr_reader :ruby_version, :openssl_version, :yaml_version, :work, :prefix

      def initialize(out: nil, work: nil, ruby_version: nil, openssl_version: nil, yaml_version: nil,
                     host_os: RbConfig::CONFIG["host_os"], host_cpu: RbConfig::CONFIG["host_cpu"],
                     jobs: nil, runner: Command.new, fetcher: nil, log: $stdout)
        @ruby_version = ruby_version || DEFAULT_RUBY_VERSION
        @openssl_version = openssl_version || DEFAULT_OPENSSL_VERSION
        @yaml_version = yaml_version || DEFAULT_YAML_VERSION
        @work = File.expand_path(work || ".runtime-build")
        @prefix = File.expand_path(out || File.join(@work, "out", "ruby"))
        @host_os = host_os.to_s
        @host_cpu = host_cpu.to_s
        @jobs = jobs || Etc.nprocessors
        @runner = runner
        @fetcher = fetcher
        @log = log
      end

      def src_dir
        File.join(work, "src")
      end

      def vendor_dir
        File.join(work, "vendor")
      end

      # ─── What is being built, for which machine ──────────────────────────

      def platform
        Tooling.platform(@host_os)
      end

      def arm?
        @host_cpu.match?(/\A(arm64|aarch64)/)
      end

      # The RubyGems platform name, which is also how releases are named.
      def triple
        case platform
        when :macos then arm? ? "arm64-darwin" : "x86_64-darwin"
        when :linux then arm? ? "aarch64-linux" : "x86_64-linux"
        else unsupported!
        end
      end

      # OpenSSL's own name for the target, which its Configure needs spelled out.
      def openssl_target
        case platform
        when :macos then arm? ? "darwin64-arm64-cc" : "darwin64-x86_64-cc"
        when :linux then arm? ? "linux-aarch64" : "linux-x86_64"
        else unsupported!
        end
      end

      def unsupported!
        raise MissingPrerequisite,
              "Unsupported platform (#{@host_os}). Windows uses the RubyInstaller portable archive: " \
              "desktop-rails-tool runtime fetch-windows --out DIR"
      end

      # ─── Sources ─────────────────────────────────────────────────────────

      def yaml_url
        "https://github.com/yaml/libyaml/releases/download/#{yaml_version}/yaml-#{yaml_version}.tar.gz"
      end

      def openssl_url
        "https://github.com/openssl/openssl/releases/download/openssl-#{openssl_version}/openssl-#{openssl_version}.tar.gz"
      end

      def ruby_url
        series = ruby_version.split(".").first(2).join(".")
        "https://cache.ruby-lang.org/pub/ruby/#{series}/ruby-#{ruby_version}.tar.gz"
      end

      # ─── argv ────────────────────────────────────────────────────────────

      def make_argv(*targets)
        [ "make", "-j#{@jobs}", *targets ]
      end

      def yaml_configure_argv
        [ "./configure", "--prefix=#{vendor_dir}", "--enable-static", "--disable-shared", "--with-pic" ]
      end

      # --libdir=lib matters more than it looks. OpenSSL installs to lib64 on
      # most Linux targets, while Ruby's configure looks in lib. libyaml is built
      # first and creates lib/, so a "symlink lib64 to lib if lib is missing"
      # fallback never fires — and Ruby then finds no static OpenSSL, silently
      # links the system one, and the extension fails at runtime with an
      # undefined symbol. Putting it in lib from the start removes the class.
      def openssl_configure_argv
        [ "./Configure", openssl_target, "no-shared", "no-tests", "no-docs",
          "--prefix=#{vendor_dir}", "--openssldir=#{File.join(vendor_dir, "ssl")}", "--libdir=lib" ]
      end

      def ruby_configure_argv
        [ "./configure",
          "--prefix=#{prefix}",
          "--enable-load-relative",
          "--disable-install-doc",
          "--with-openssl-dir=#{vendor_dir}",
          "--with-libyaml-dir=#{vendor_dir}",
          "--without-gmp",
          "--enable-shared=no" ]
      end

      # pkg-config must see the vendored libraries and nothing else, or
      # configure and the extensions' extconf.rb wander into a package
      # manager's prefix and link something the bundle does not carry.
      #
      # Clearing PKG_CONFIG_PATH is not enough. It only adds directories;
      # Homebrew's pkg-config has /opt/homebrew/lib/pkgconfig compiled into its
      # default search path, so psych's extconf still found Homebrew's libyaml
      # there and psych.bundle linked /opt/homebrew/opt/libyaml/lib/libyaml-0.2.dylib
      # — which verification caught when building Ruby 4.0. PKG_CONFIG_LIBDIR
      # replaces that default path, so the vendor prefix is all there is.
      #
      # Applied to make as well as configure, because extconf.rb runs during
      # make.
      def ruby_build_env
        { "PKG_CONFIG_PATH" => nil, "PKG_CONFIG_LIBDIR" => File.join(vendor_dir, "lib", "pkgconfig") }
      end

      # ─── What is already done ────────────────────────────────────────────
      #
      # Each stage is skipped when its product exists, so a cached vendor
      # directory in CI saves the twenty minutes OpenSSL takes.

      def yaml_built?
        File.exist?(File.join(vendor_dir, "lib", "libyaml.a"))
      end

      def openssl_built?
        %w[lib lib64].any? { |dir| File.exist?(File.join(vendor_dir, dir, "libssl.a")) }
      end

      def ruby_built?
        File.executable?(File.join(prefix, "bin", "ruby"))
      end

      # ─── Doing it ────────────────────────────────────────────────────────

      def build!
        step "Target: #{triple} (openssl #{openssl_target})"
        FileUtils.mkdir_p([ src_dir, vendor_dir, File.dirname(prefix) ])

        if yaml_built?
          step "libyaml #{yaml_version} already built"
        else
          step "Building libyaml #{yaml_version} (static)"
          dir = unpack(yaml_url, "yaml-#{yaml_version}")
          compile(dir, yaml_configure_argv, make_argv, [ "make", "install" ])
        end

        if openssl_built?
          step "OpenSSL #{openssl_version} already built"
        else
          step "Building OpenSSL #{openssl_version} (static) — the long pole, ~20 min"
          dir = unpack(openssl_url, "openssl-#{openssl_version}")
          compile(dir, openssl_configure_argv, make_argv, [ "make", "install_sw" ])
          unless File.exist?(File.join(vendor_dir, "lib", "libcrypto.a"))
            raise CheckFailed, "OpenSSL did not install a static libcrypto into #{File.join(vendor_dir, "lib")}"
          end
        end

        if ruby_built?
          step "Ruby #{ruby_version} already built at #{prefix}"
        else
          step "Building Ruby #{ruby_version} with --enable-load-relative"
          dir = unpack(ruby_url, "ruby-#{ruby_version}")
          compile(dir, ruby_configure_argv, make_argv, [ "make", "install" ], env: ruby_build_env)
        end

        step "Built"
        version = @runner.capture!([ File.join(prefix, "bin", "ruby"), "-v" ], clean_ruby: true).strip
        @log.puts "  #{version}"
        @log.puts "  #{prefix}  (#{Tooling.human_size(Tooling.size_of(prefix))})"
        @log.puts "  triple: #{triple}"
        prefix
      end

      private

      def step(message)
        @log.puts "\n\e[1m==> #{message}\e[0m"
      end

      # configure, make, install, each in the source directory. Quiet unless
      # asked otherwise: a build prints tens of thousands of lines, and the ones
      # that matter when it fails are the last few, which the failure carries.
      def compile(dir, configure, make, install, env: {})
        [ configure, make, install ].each do |argv|
          @runner.run(argv, chdir: dir, env: env, quiet: true, clean_ruby: true)
        end
      end

      # Downloaded once into src/ and reused; unpacked fresh each time, so a
      # half-finished earlier build of the same version cannot leak in.
      def unpack(url, directory)
        archive = File.join(src_dir, File.basename(url))
        unless File.exist?(archive)
          @log.puts "  downloading #{url}"
          partial = "#{archive}.part"
          fetcher.call(url, partial)
          File.rename(partial, archive)
        end
        FileUtils.rm_rf(File.join(src_dir, directory))
        @runner.run([ "tar", "-xzf", archive, "-C", src_dir ])
        File.join(src_dir, directory)
      end

      def fetcher
        @fetcher ||= begin
          require "desktop_rails/prebuilt"
          Prebuilt::HttpFetcher.new
        end
      end
    end
  end
end

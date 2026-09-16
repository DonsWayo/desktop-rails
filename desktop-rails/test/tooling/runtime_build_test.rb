require_relative "tooling_test_helper"
require "desktop_rails/packaging"
require "desktop_rails/tooling/runtime_build"

# What the runtime build decides, with configure and make replaced by a
# recorder. The compile itself is proved in CI (build-runtime.yml), where a
# relocatable interpreter is built on each platform and verified.
class ToolingRuntimeBuildTest < Minitest::Test
  include ToolingTestSupport

  Build = DesktopRails::Tooling::RuntimeBuild

  def build(host_os: "darwin24", host_cpu: "arm64", **options)
    Build.new(host_os: host_os, host_cpu: host_cpu, jobs: 8, log: StringIO.new, **options)
  end

  def test_each_supported_machine_gets_its_triple_and_openssl_target
    {
      [ "darwin24", "arm64" ] => [ "arm64-darwin", "darwin64-arm64-cc" ],
      [ "darwin23", "x86_64" ] => [ "x86_64-darwin", "darwin64-x86_64-cc" ],
      [ "linux-gnu", "x86_64" ] => [ "x86_64-linux", "linux-x86_64" ],
      [ "linux-gnu", "aarch64" ] => [ "aarch64-linux", "linux-aarch64" ]
    }.each do |(os, cpu), (triple, target)|
      b = build(host_os: os, host_cpu: cpu)
      assert_equal triple, b.triple, "#{os} #{cpu}"
      assert_equal target, b.openssl_target, "#{os} #{cpu}"
    end
  end

  def test_windows_is_pointed_at_the_portable_archive
    error = assert_raises(DesktopRails::Tooling::MissingPrerequisite) do
      build(host_os: "mingw32", host_cpu: "x64").triple
    end
    assert_match(/fetch-windows/, error.message)
  end

  def test_source_urls
    b = build(ruby_version: "3.4.8", openssl_version: "3.5.4", yaml_version: "0.2.5")
    assert_equal "https://cache.ruby-lang.org/pub/ruby/3.4/ruby-3.4.8.tar.gz", b.ruby_url
    assert_equal "https://github.com/openssl/openssl/releases/download/openssl-3.5.4/openssl-3.5.4.tar.gz", b.openssl_url
    assert_equal "https://github.com/yaml/libyaml/releases/download/0.2.5/yaml-0.2.5.tar.gz", b.yaml_url
  end

  def test_openssl_installs_into_lib_not_lib64
    # OpenSSL defaults to lib64 on most Linux targets while Ruby's configure
    # looks in lib; Ruby then silently links the system OpenSSL and the
    # extension dies at runtime on an undefined symbol.
    b = build(host_os: "linux-gnu", host_cpu: "x86_64", work: "/w")
    argv = b.openssl_configure_argv
    assert_equal [ "./Configure", "linux-x86_64", "no-shared", "no-tests", "no-docs" ], argv.first(5)
    assert_includes argv, "--libdir=lib"
    assert_includes argv, "--prefix=/w/vendor"
    assert_includes argv, "--openssldir=/w/vendor/ssl"
  end

  def test_ruby_is_configured_to_relocate_against_the_vendored_libraries
    b = build(work: "/w", out: "/o/ruby")
    argv = b.ruby_configure_argv
    %w[--enable-load-relative --disable-install-doc --without-gmp --enable-shared=no
       --prefix=/o/ruby --with-openssl-dir=/w/vendor --with-libyaml-dir=/w/vendor].each do |flag|
      assert_includes argv, flag
    end
  end

  def test_pkg_config_sees_only_the_vendored_libraries
    # Clearing PKG_CONFIG_PATH alone left Homebrew's compiled-in search path in
    # place, and psych.bundle linked Homebrew's libyaml. PKG_CONFIG_LIBDIR
    # replaces the default path rather than adding to it.
    env = build(work: "/w").ruby_build_env
    assert_equal "/w/vendor/lib/pkgconfig", env["PKG_CONFIG_LIBDIR"]
    assert env.key?("PKG_CONFIG_PATH"), "PKG_CONFIG_PATH must be unset, not inherited"
    assert_nil env["PKG_CONFIG_PATH"]
  end

  def test_versions_are_parameters_with_defaults
    b = build
    assert_equal [ Build::DEFAULT_RUBY_VERSION, Build::DEFAULT_OPENSSL_VERSION, Build::DEFAULT_YAML_VERSION ],
                 [ b.ruby_version, b.openssl_version, b.yaml_version ]
    b = build(ruby_version: "4.0.7", openssl_version: "4.0.2")
    assert_equal "https://cache.ruby-lang.org/pub/ruby/4.0/ruby-4.0.7.tar.gz", b.ruby_url
    assert_match(%r{openssl-4\.0\.2/openssl-4\.0\.2\.tar\.gz\z}, b.openssl_url)
  end

  def test_libyaml_is_static_and_position_independent
    assert_equal [ "./configure", "--prefix=/w/vendor", "--enable-static", "--disable-shared", "--with-pic" ],
                 build(work: "/w").yaml_configure_argv
  end

  def test_make_uses_every_core
    assert_equal [ "make", "-j8", "install" ], build.make_argv("install")
  end

  def test_the_interpreter_defaults_into_the_work_directory
    assert_equal "/w/out/ruby", build(work: "/w").prefix
  end

  def test_a_full_build_downloads_unpacks_configures_makes_and_installs_in_order
    Dir.mktmpdir do |dir|
      runner = RecordingRunner.new
      prefix = File.join(dir, "out", "ruby")
      # The last step produces the interpreter, as a real `make install` does.
      runner.on(->(argv) { argv == [ "make", "install" ] }) do |_, options|
        if options[:chdir].end_with?("ruby-3.4.8")
          executable(File.join(prefix, "bin", "ruby"))
        elsif options[:chdir].end_with?("yaml-0.2.5")
          write(File.join(dir, "vendor", "lib", "libyaml.a"))
        end
      end
      runner.on(->(argv) { argv == [ "make", "install_sw" ] }) do
        write(File.join(dir, "vendor", "lib", "libcrypto.a"))
        write(File.join(dir, "vendor", "lib", "libssl.a"))
      end
      runner.on(->(argv) { argv.last == "-v" }, output: "ruby 3.4.8\n")
      fetched = []
      fetcher = ->(url, path) { fetched << url; write(path, "archive") }

      b = build(work: dir, out: prefix, ruby_version: "3.4.8", openssl_version: "3.5.4", runner: runner, fetcher: fetcher)
      assert_equal prefix, b.build!

      assert_equal [ b.yaml_url, b.openssl_url, b.ruby_url ], fetched
      steps = runner.calls.map { |argv, options| [ argv.first, File.basename(options[:chdir].to_s) ] }
      assert_equal [
        [ "tar", "" ], [ "./configure", "yaml-0.2.5" ], [ "make", "yaml-0.2.5" ], [ "make", "yaml-0.2.5" ],
        [ "tar", "" ], [ "./Configure", "openssl-3.5.4" ], [ "make", "openssl-3.5.4" ], [ "make", "openssl-3.5.4" ],
        [ "tar", "" ], [ "./configure", "ruby-3.4.8" ], [ "make", "ruby-3.4.8" ], [ "make", "ruby-3.4.8" ],
        [ File.join(prefix, "bin", "ruby"), "" ]
      ], steps

      compile = runner.calls.select { |_, options| options[:chdir] }
      assert(compile.all? { |_, options| options[:clean_ruby] && options[:quiet] },
             "every compile step runs quietly and outside any bundle")
      # extconf.rb runs during make, so the pkg-config restriction has to reach
      # every Ruby step, not only configure.
      ruby_steps = runner.calls.select { |_, options| options[:chdir].to_s.end_with?("ruby-3.4.8") }
      assert_equal 3, ruby_steps.size
      ruby_steps.each { |_, options| assert_equal b.ruby_build_env, options[:env] }
      yaml_steps = runner.calls.select { |_, options| options[:chdir].to_s.end_with?("yaml-0.2.5") }
      yaml_steps.each { |_, options| assert_empty options[:env] }
    end
  end

  def test_what_is_already_built_is_not_built_again
    # CI caches vendor/ on the dependency versions; OpenSSL alone is twenty
    # minutes, so a cache hit has to skip it.
    Dir.mktmpdir do |dir|
      write(File.join(dir, "vendor", "lib", "libyaml.a"))
      write(File.join(dir, "vendor", "lib64", "libssl.a"))
      executable(File.join(dir, "out", "ruby", "bin", "ruby"))
      runner = RecordingRunner.new
      fetcher = ->(url, _) { flunk "downloaded #{url}" }

      build(work: dir, runner: runner, fetcher: fetcher).build!
      assert_equal [ [ File.join(dir, "out", "ruby", "bin", "ruby"), "-v" ] ], runner.argvs
    end
  end

  def test_openssl_that_installs_no_static_libcrypto_into_lib_fails_the_build
    Dir.mktmpdir do |dir|
      write(File.join(dir, "vendor", "lib", "libyaml.a"))
      runner = RecordingRunner.new
      runner.on(->(argv) { argv == [ "make", "install_sw" ] }) { write(File.join(dir, "vendor", "lib64", "libcrypto.a")) }
      error = assert_raises(DesktopRails::Tooling::CheckFailed) do
        build(work: dir, runner: runner, fetcher: ->(_, path) { write(path) }).build!
      end
      assert_match(/static libcrypto/, error.message)
    end
  end

  def test_an_interrupted_download_is_not_mistaken_for_a_complete_one
    Dir.mktmpdir do |dir|
      fetcher = ->(_, path) { write(path, "half"); raise DesktopRails::Packaging::DownloadFailed, "connection reset" }
      assert_raises(DesktopRails::Packaging::DownloadFailed) do
        build(work: dir, runner: RecordingRunner.new, fetcher: fetcher).build!
      end
      refute File.exist?(File.join(dir, "src", "yaml-0.2.5.tar.gz")),
             "a partial archive under the final name would be reused by the next run"
    end
  end
end

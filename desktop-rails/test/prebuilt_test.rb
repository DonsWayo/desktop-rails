require_relative "test_helper"
require_relative "packaging_test"
require "desktop_rails/packaging"
require "desktop_rails/prebuilt"
require "digest"
require "socket"
require "tmpdir"
require "fileutils"

# The names and checks a release download depends on. Every one is a pure
# function, so they are asserted directly; the release workflow calls the same
# functions to name what it uploads, which is what keeps these assertions about
# the real release and not about a copy of its naming scheme.
class PrebuiltReleaseNamingTest < Minitest::Test
  P = DesktopRails::Packaging

  def test_the_gem_version_is_the_release_tag
    assert_equal "v0.3.0.pre1", P.release_tag("0.3.0.pre1")
    assert_equal "v1.2.3", P.release_tag("1.2.3")
  end

  def test_the_semver_form_cargo_and_npm_need
    assert_equal "0.3.0-pre.1", P.semver("0.3.0.pre1")
    assert_equal "1.2.3", P.semver("1.2.3")
    assert_equal "1.0.0-rc.2", P.semver("1.0.0.rc.2")
    assert_equal "2.0.0", P.semver("2")
  end

  def test_cargo_and_npm_carry_the_gem_version
    # The shell reports its crate version to the updater, and the release is
    # named after the gem. If these drift, the shell a gem downloads claims to
    # be a version it is not.
    root = File.expand_path("../..", __dir__)
    cargo = File.join(root, "src-tauri", "Cargo.toml")
    npm = File.join(root, "package.json")
    skip "not in a checkout" unless File.exist?(cargo) && File.exist?(npm)

    expected = P.semver(DesktopRails::VERSION)
    assert_equal expected, File.read(cargo)[/^version\s*=\s*"([^"]+)"/, 1]
    assert_equal expected, JSON.parse(File.read(npm))["version"]
  end

  def test_prerelease_follows_rubygems
    assert P.prerelease?("0.3.0.pre1")
    refute P.prerelease?("0.3.0")
  end

  def test_asset_names_are_deterministic_per_platform
    assert_equal "desktop-rails-runtime-0.3.0.pre1-arm64-darwin.tar.gz",
                 P.runtime_asset_name(version: "0.3.0.pre1", triple: "arm64-darwin")
    assert_equal "desktop-rails-runtime-0.3.0.pre1-x64-mingw-ucrt.zip",
                 P.runtime_asset_name(version: "0.3.0.pre1", triple: "x64-mingw-ucrt")
    assert_equal "desktop-rails-shell-0.3.0.pre1-x86_64-linux",
                 P.shell_asset_name(version: "0.3.0.pre1", triple: "x86_64-linux")
    assert_equal "desktop-rails-shell-0.3.0.pre1-x64-mingw-ucrt.exe",
                 P.shell_asset_name(version: "0.3.0.pre1", triple: "x64-mingw-ucrt")
  end

  def test_a_release_carries_a_runtime_and_a_shell_for_every_platform_and_the_checksums
    names = P.release_asset_names(version: "1.0.0")
    assert_equal 2 * P::RELEASE_TRIPLES.size + 1, names.size
    assert_includes names, "SHA256SUMS"
    assert_equal names.uniq, names
    %w[arm64-darwin x86_64-darwin x86_64-linux x64-mingw-ucrt].each do |triple|
      assert(names.any? { |n| n.start_with?("desktop-rails-runtime-1.0.0-#{triple}.") }, triple)
      assert(names.any? { |n| n.start_with?("desktop-rails-shell-1.0.0-#{triple}") }, triple)
    end
  end

  def test_urls_are_the_github_release_download_layout
    assert_equal "https://github.com/DonsWayo/desktop-rails/releases/download/v0.3.0.pre1/SHA256SUMS",
                 P.release_asset_url("SHA256SUMS", version: "0.3.0.pre1")
    assert_equal "https://mirror.example/dr/v1.0.0/x",
                 P.release_asset_url("x", version: "1.0.0", base_url: "https://mirror.example/dr/")
  end

  def test_version_and_base_url_default_to_this_gem_and_can_be_overridden
    assert_equal DesktopRails::VERSION, P.release_version(env: {})
    assert_equal P::DEFAULT_RELEASE_URL, P.release_base_url(env: {})

    DesktopRails.configure do |c|
      c.release_version = "9.9.9"
      c.release_url = "https://config.example/releases/"
    end
    assert_equal "9.9.9", P.release_version(env: {})
    assert_equal "https://config.example/releases", P.release_base_url(env: {})

    env = { "DESKTOP_RAILS_RELEASE_VERSION" => "1.0.0", "DESKTOP_RAILS_RELEASE_URL" => "https://env.example" }
    assert_equal "1.0.0", P.release_version(env: env), "the environment wins over the initializer"
    assert_equal "https://env.example", P.release_base_url(env: env)
  end

  def test_the_host_platform_maps_to_a_release_triple
    assert_equal "arm64-darwin", P.release_triple(host_os: "darwin25", host_cpu: "arm64")
    assert_equal "arm64-darwin", P.release_triple(host_os: "darwin23", host_cpu: "aarch64")
    assert_equal "x86_64-darwin", P.release_triple(host_os: "darwin24", host_cpu: "x86_64")
    assert_equal "x86_64-linux", P.release_triple(host_os: "linux-gnu", host_cpu: "x86_64")
    assert_equal "x86_64-linux", P.release_triple(host_os: "linux", host_cpu: "x86_64")
    assert_equal "x64-mingw-ucrt", P.release_triple(host_os: "mingw32", host_cpu: "x64")
    assert_equal "x64-mingw-ucrt", P.release_triple(host_os: "mingw32", host_cpu: "x86_64")
  end

  def test_platforms_no_release_covers_have_no_triple
    # nil sends desktop:runtime to build from source instead.
    assert_nil P.release_triple(host_os: "linux-gnu", host_cpu: "aarch64")
    assert_nil P.release_triple(host_os: "linux-musl", host_cpu: "x86_64"), "the published Linux build links glibc"
    assert_nil P.release_triple(host_os: "freebsd14", host_cpu: "amd64")
    assert_nil P.release_triple(host_os: "mingw32", host_cpu: "aarch64")
  end

  def test_every_published_triple_is_one_a_host_can_map_to
    hosts = [ %w[darwin arm64], %w[darwin x86_64], %w[linux-gnu x86_64], %w[mingw32 x64] ]
    assert_equal P::RELEASE_TRIPLES.sort, hosts.map { |os, cpu| P.release_triple(host_os: os, host_cpu: cpu) }.sort
  end
end

class PrebuiltChecksumTest < Minitest::Test
  P = DesktopRails::Packaging
  A = "a" * 64
  B = "B" * 64

  def test_parses_sha256sum_output_in_text_and_binary_mode
    sums = P.parse_checksums(<<~SUMS)
      #{A}  desktop-rails-runtime-1.0.0-arm64-darwin.tar.gz
      #{B} *desktop-rails-shell-1.0.0-x64-mingw-ucrt.exe
      # a comment is skipped, not fatal
      not a checksum line
    SUMS
    assert_equal({ "desktop-rails-runtime-1.0.0-arm64-darwin.tar.gz" => A,
                   "desktop-rails-shell-1.0.0-x64-mingw-ucrt.exe" => B.downcase }, sums)
  end

  def test_tolerates_crlf
    assert_equal({ "x" => A }, P.parse_checksums("#{A}  x\r\n"))
  end

  def test_an_asset_missing_from_the_checksums_is_not_published
    error = assert_raises(P::NotPublished) { P.expected_checksum!({ "other" => A }, "wanted") }
    assert_match(/wanted/, error.message)
  end

  def test_verifies_a_file_against_its_checksum
    Dir.mktmpdir do |dir|
      path = File.join(dir, "asset")
      File.binwrite(path, "contents")
      expected = Digest::SHA256.hexdigest("contents")
      assert_equal expected, P.verify_checksum!(path, expected.upcase)

      error = assert_raises(P::DownloadFailed) { P.verify_checksum!(path, A) }
      assert_match(/expected #{A}/, error.message)
      assert_match(/got      #{expected}/, error.message)
    end
  end

  def test_a_redirect_is_resolved_against_the_request
    assert_equal "https://objects.githubusercontent.com/x?sig=1",
                 P.redirect_target("https://github.com/a/b", "https://objects.githubusercontent.com/x?sig=1")
    assert_equal "https://mirror.example/files/y", P.redirect_target("https://mirror.example/dl/x", "/files/y")
  end

  def test_a_redirect_from_https_to_http_is_refused
    # The checksum file travels the same way as the asset, so a downgrade would
    # let an attacker on the network replace both.
    assert_raises(P::DownloadFailed) { P.redirect_target("https://github.com/a", "http://evil.example/a") }
  end
end

class PrebuiltCommandTest < Minitest::Test
  include PackagingSandbox
  P = DesktopRails::Packaging

  def test_tar_unpacks_on_macos_and_linux
    assert_equal [ "tar", "-xzf", "/a b/r.tar.gz", "-C", "/out dir" ],
                 P.extract_command("/a b/r.tar.gz", into: "/out dir", triple: "x86_64-linux")
  end

  def test_expand_archive_unpacks_on_windows_with_literal_paths
    argv = P.extract_command("C:\\Users\\O'Brien\\r.zip", into: "C:\\build dir\\x", triple: "x64-mingw-ucrt")
    assert_equal %w[pwsh -NoProfile -NonInteractive -Command], argv.first(4)
    assert_equal 5, argv.size, "the whole command is one argument, not re-split"
    # Single backslashes: a PowerShell single-quoted literal takes them as they
    # are, and doubling them has broken Windows paths here before.
    assert_includes argv.last, "-LiteralPath 'C:\\Users\\O''Brien\\r.zip'"
    assert_includes argv.last, "-DestinationPath 'C:\\build dir\\x'"
    refute_includes argv.last, "\\\\"
  end

  def test_the_runtime_check_is_the_same_tool_on_every_platform
    # Windows used to be asked a shorter list of questions from a string in
    # this module, and fixes landed in one list and not the other.
    tool = File.expand_path("../exe/desktop-rails-tool", __dir__)
    assert_equal [ RbConfig.ruby, tool, "runtime", "verify", "C:/r dir" ], P.runtime_check_command("C:/r dir")
  end

  def test_from_source_switches
    refute P.runtime_from_source?(env: {})
    refute P.runtime_from_source?(env: { "DESKTOP_RAILS_RUNTIME_FROM_SOURCE" => "" })
    %w[0 false no off FALSE].each do |value|
      refute P.runtime_from_source?(env: { "DESKTOP_RAILS_RUNTIME_FROM_SOURCE" => value }), value
    end
    %w[1 true yes].each do |value|
      assert P.runtime_from_source?(env: { "DESKTOP_RAILS_RUNTIME_FROM_SOURCE" => value }), value
      assert P.shell_from_source?(env: { "DESKTOP_RAILS_SHELL_FROM_SOURCE" => value }), value
    end
  end

  def test_the_downloaded_shell_is_found_last_and_per_version
    with_sandbox do |paths|
      on_platform(:macos) do
        path = P.downloaded_shell_path(version: "1.2.3")
        assert_equal File.join(paths[:root], "build", "shell", "1.2.3", "desktop-rails"), path.to_s
        assert_nil P.shell_binary

        FileUtils.mkdir_p(path.dirname)
        File.write(path, "")
        FileUtils.chmod(0o755, path)
        with_env("DESKTOP_RAILS_RELEASE_VERSION" => "1.2.3") do
          assert_equal path.to_s, P.shell_binary
          assert_equal path.to_s, P.shell_candidates.last, "an explicit or checkout shell must win"
        end
      end
    end
  end

  def test_an_explicit_shell_wins_over_a_downloaded_one
    with_sandbox(shell: true) do |paths|
      path = P.downloaded_shell_path
      FileUtils.mkdir_p(path.dirname)
      File.write(path, "")
      FileUtils.chmod(0o755, path)
      assert_equal paths[:shell], P.shell_binary
    end
  end

  def test_building_the_shell_needs_a_checkout
    with_sandbox do
      error = assert_raises(P::MissingPrerequisite) { P.shell_build_command(env: { "PATH" => "" }) }
      assert_match(/Cargo\.toml/, error.message)
    end
  end

  def test_building_the_shell_needs_cargo
    with_sandbox do |paths|
      FileUtils.mkdir_p(File.join(paths[:root], "src-tauri"))
      File.write(File.join(paths[:root], "src-tauri", "Cargo.toml"), "")
      on_platform(:macos) do
        error = assert_raises(P::MissingPrerequisite) { P.shell_build_command(env: { "PATH" => paths[:root] }) }
        assert_match(/cargo is not on PATH/, error.message)

        bin = File.join(paths[:root], "bin")
        FileUtils.mkdir_p(bin)
        File.write(File.join(bin, "cargo"), "")
        FileUtils.chmod(0o755, File.join(bin, "cargo"))
        argv = P.shell_build_command(env: { "PATH" => bin })
        assert_equal [ File.join(bin, "cargo"), "build", "--release", "--manifest-path",
                       File.join(paths[:root], "src-tauri", "Cargo.toml") ], argv
      end
    end
  end
end

# The download itself, with the network replaced by a hash of URL to bytes.
# Extraction is real — tar is on every machine this suite runs on — because
# "the archive unpacks into a runtime" is the claim, and a fake extractor would
# only restate it.
class PrebuiltInstallTest < Minitest::Test
  P = DesktopRails::Packaging
  VERSION = "1.0.0"
  BASE = "https://releases.example/dr"
  TRIPLE = "x86_64-linux"

  class FakeFetcher
    attr_reader :requested

    def initialize(files)
      @files = files
      @requested = []
    end

    def call(url, destination)
      @requested << url
      body = @files.fetch(url) { raise DesktopRails::Packaging::NotPublished, "#{url} does not exist." }
      File.binwrite(destination, body)
      destination
    end
  end

  def setup
    super
    skip "extraction uses tar" if Gem.win_platform?
    @tmp = Dir.mktmpdir
  end

  def teardown
    FileUtils.rm_rf(@tmp) if @tmp
    super
  end

  def url(name)
    P.release_asset_url(name, version: VERSION, base_url: BASE)
  end

  def runtime_archive(root: "ruby")
    src = File.join(@tmp, "src")
    FileUtils.mkdir_p(File.join(src, root, "bin"))
    File.write(File.join(src, root, "bin", "ruby"), "#!/bin/sh\necho ruby\n")
    FileUtils.chmod(0o755, File.join(src, root, "bin", "ruby"))
    archive = File.join(@tmp, "runtime.tar.gz")
    assert system("tar", "-czf", archive, "-C", src, root)
    File.binread(archive)
  ensure
    FileUtils.rm_rf(src)
  end

  def release(files, sums: nil)
    sums ||= files.map { |name, body| "#{Digest::SHA256.hexdigest(body)}  #{name}\n" }.join
    FakeFetcher.new(files.to_h { |name, body| [ url(name), body ] }.merge(url("SHA256SUMS") => sums))
  end

  def install_runtime(fetcher, into: File.join(@tmp, "build", "runtime"))
    DesktopRails::Prebuilt.install_runtime(into: into, triple: TRIPLE, version: VERSION, base_url: BASE,
                                           fetcher: fetcher, log: ->(_) { })
  end

  def test_downloads_verifies_and_unpacks_a_runtime
    name = P.runtime_asset_name(version: VERSION, triple: TRIPLE)
    fetcher = release({ name => runtime_archive })
    into = install_runtime(fetcher)

    assert P.runtime?(into), "bin/ruby should be executable at #{into}"
    assert_equal [ url("SHA256SUMS"), url(name) ], fetcher.requested, "checksums first, then the asset"
    assert_equal [ "runtime" ], Dir.children(File.join(@tmp, "build")), "no download debris is left behind"
  end

  def test_a_checksum_mismatch_installs_nothing
    name = P.runtime_asset_name(version: VERSION, triple: TRIPLE)
    fetcher = release({ name => runtime_archive }, sums: "#{"0" * 64}  #{name}\n")
    into = File.join(@tmp, "build", "runtime")

    assert_raises(P::DownloadFailed) { install_runtime(fetcher, into: into) }
    refute File.exist?(into), "a runtime that failed its checksum must not be where runtime_dir looks"
    assert_empty Dir.children(File.join(@tmp, "build"))
  end

  def test_a_missing_release_is_not_published
    error = assert_raises(P::NotPublished) { install_runtime(FakeFetcher.new({})) }
    assert_match(/No release v1\.0\.0/, error.message)
  end

  def test_a_release_without_this_platform_is_not_published
    fetcher = release({ P.runtime_asset_name(version: VERSION, triple: "arm64-darwin") => "x" })
    error = assert_raises(P::NotPublished) { install_runtime(fetcher) }
    assert_match(/x86_64-linux/, error.message)
  end

  def test_an_archive_without_the_expected_root_is_refused
    name = P.runtime_asset_name(version: VERSION, triple: TRIPLE)
    into = File.join(@tmp, "build", "runtime")
    error = assert_raises(P::DownloadFailed) { install_runtime(release({ name => runtime_archive(root: "other") }), into: into) }
    assert_match(%r{ruby/bin/ruby}, error.message)
    refute File.exist?(into)
  end

  def test_does_not_unpack_over_something_already_there
    into = File.join(@tmp, "build", "runtime")
    FileUtils.mkdir_p(File.join(into, "half-built"))
    name = P.runtime_asset_name(version: VERSION, triple: TRIPLE)
    error = assert_raises(P::DownloadFailed) { install_runtime(release({ name => runtime_archive }), into: into) }
    assert_match(/Delete it/, error.message)
  end

  def test_downloads_an_executable_shell
    name = P.shell_asset_name(version: VERSION, triple: TRIPLE)
    fetcher = release({ name => "\x7FELF shell" })
    into = File.join(@tmp, "build", "shell", VERSION, "desktop-rails")

    DesktopRails::Prebuilt.install_shell(into: into, triple: TRIPLE, version: VERSION, base_url: BASE,
                                         fetcher: fetcher, log: ->(_) { })
    assert File.executable?(into)
    assert_equal "\x7FELF shell".b, File.binread(into)
    assert_equal [ "desktop-rails" ], Dir.children(File.dirname(into))
  end

  def test_a_shell_that_fails_its_checksum_is_not_installed
    name = P.shell_asset_name(version: VERSION, triple: TRIPLE)
    fetcher = release({ name => "tampered" }, sums: "#{Digest::SHA256.hexdigest("original")}  #{name}\n")
    into = File.join(@tmp, "build", "shell", VERSION, "desktop-rails")

    assert_raises(P::DownloadFailed) do
      DesktopRails::Prebuilt.install_shell(into: into, triple: TRIPLE, version: VERSION, base_url: BASE,
                                           fetcher: fetcher, log: ->(_) { })
    end
    refute File.exist?(into)
  end
end

# The real fetcher against a server on the loopback interface: no network, but
# real HTTP, including the redirect GitHub answers every release download with.
class PrebuiltHttpFetcherTest < Minitest::Test
  def setup
    super
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @routes = {}
    @thread = Thread.new do
      loop do
        client = @server.accept
        request_line = client.gets.to_s
        while (line = client.gets) && line != "\r\n"; end
        path = request_line.split[1]
        status, headers, body = @routes.fetch(path, [ 404, {}, "not found" ])
        client.write("HTTP/1.1 #{status} X\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n")
        headers.each { |k, v| client.write("#{k}: #{v}\r\n") }
        client.write("\r\n#{body}")
        client.close
      rescue IOError, SystemCallError
        break
      end
    end
    @tmp = Dir.mktmpdir
  end

  def teardown
    @server&.close
    @thread&.kill
    FileUtils.rm_rf(@tmp) if @tmp
    super
  end

  def base
    "http://127.0.0.1:#{@port}"
  end

  def fetch(path)
    destination = File.join(@tmp, "out")
    DesktopRails::Prebuilt::HttpFetcher.new(open_timeout: 5, read_timeout: 5).call("#{base}#{path}", destination)
    File.binread(destination)
  end

  def test_follows_redirects_to_the_body
    @routes["/releases/download/v1/asset"] = [ 302, { "Location" => "#{base}/objects/signed?x=1" }, "" ]
    @routes["/objects/signed?x=1"] = [ 200, {}, "the bytes" ]
    assert_equal "the bytes", fetch("/releases/download/v1/asset")
  end

  def test_follows_a_relative_redirect
    @routes["/a"] = [ 301, { "Location" => "/b" }, "" ]
    @routes["/b"] = [ 200, {}, "b" ]
    assert_equal "b", fetch("/a")
  end

  def test_not_found_is_not_published
    assert_raises(DesktopRails::Packaging::NotPublished) { fetch("/missing") }
  end

  def test_a_server_error_is_a_failed_download_not_a_missing_one
    @routes["/broken"] = [ 500, {}, "" ]
    assert_raises(DesktopRails::Packaging::DownloadFailed) { fetch("/broken") }
  end

  def test_gives_up_on_a_redirect_loop
    @routes["/loop"] = [ 302, { "Location" => "/loop" }, "" ]
    error = assert_raises(DesktopRails::Packaging::DownloadFailed) { fetch("/loop") }
    assert_match(/redirected more than/, error.message)
  end

  def test_a_refused_connection_is_a_failed_download
    port = @port
    @server.close
    @thread.kill
    destination = File.join(@tmp, "out")
    assert_raises(DesktopRails::Packaging::DownloadFailed) do
      DesktopRails::Prebuilt::HttpFetcher.new(open_timeout: 2).call("http://127.0.0.1:#{port}/x", destination)
    end
  end
end

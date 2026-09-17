# frozen_string_literal: true

require "fileutils"
require "net/http"
require "pathname"
require "tmpdir"
require "uri"
require "desktop_rails/packaging"
require "desktop_rails/version"

module DesktopRails
  # Downloading the interpreter and the shell a release publishes, so that
  # packaging an app needs neither a C toolchain nor Rust.
  #
  # Every decision — which URL, which asset, what the checksum file says, how
  # to unpack — lives in DesktopRails::Packaging as a function that touches
  # nothing. This module is the part that does touch things, and it takes the
  # fetcher and the extractor as arguments so the tests can hand it files
  # instead of a network.
  #
  # What the checksum proves: that the file arrived whole and is the file the
  # release workflow uploaded next to it. It does not prove who uploaded it —
  # SHA256SUMS comes from the same release — so trust still rests on GitHub and
  # on this repository's release process.
  module Prebuilt
    NotPublished = Packaging::NotPublished
    DownloadFailed = Packaging::DownloadFailed

    # GET with redirects, streamed to a file. Plain Net::HTTP: no gem to add to
    # a Rails app for something run once per machine.
    class HttpFetcher
      MAX_REDIRECTS = 5
      ATTEMPTS = 4

      # A response worth asking for again: GitHub's release downloads answer 5xx
      # and 429 now and then, and the next request usually succeeds.
      class Transient < StandardError; end

      def initialize(open_timeout: 30, read_timeout: 300, max_redirects: MAX_REDIRECTS,
                     attempts: ATTEMPTS, sleeper: ->(seconds) { sleep(seconds) })
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @max_redirects = max_redirects
        @attempts = attempts
        @sleeper = sleeper
      end

      # Retries what a moment can fix, with a short backoff. A single reset
      # connection used to fail the whole of desktop:package; CI saw exactly that
      # ("Connection reset by peer - SSL_connect") on a GitHub-hosted runner.
      # Nothing that is an answer rather than an accident is retried: a missing
      # release, a redirect loop, or a redirect to plain http.
      def call(url, destination)
        attempt = 1
        begin
          follow(url, destination)
        rescue NotPublished, DownloadFailed
          raise
        rescue StandardError => e
          # Offline, DNS, TLS, a timeout, a 5xx: all of them are "try again", none
          # of them is "this release does not exist", so none may fall back to a
          # build.
          if attempt < @attempts
            @sleeper.call(2**(attempt - 1))
            attempt += 1
            retry
          end
          detail = e.is_a?(Transient) ? e.message : "#{e.class}: #{e.message}"
          raise DownloadFailed, "Could not download #{url} after #{attempt} attempts: #{detail}"
        end
      end

      private

      def follow(url, destination)
        current = url.to_s
        (@max_redirects + 1).times do
          location = get(current, destination)
          return destination unless location

          current = Packaging.redirect_target(current, location)
        end
        raise DownloadFailed, "#{url} redirected more than #{@max_redirects} times; giving up."
      end

      # Returns the Location to follow, or nil once the body is on disk.
      def get(url, destination)
        uri = URI(url)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                        open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
          request = Net::HTTP::Get.new(uri)
          request["User-Agent"] = "desktop-rails/#{DesktopRails::VERSION}"
          http.request(request) do |response|
            case response
            when Net::HTTPSuccess
              File.open(destination, "wb") { |file| response.read_body { |chunk| file.write(chunk) } }
              return nil
            when Net::HTTPRedirection
              return response["location"] || raise(DownloadFailed, "#{url} redirected without a Location.")
            when Net::HTTPNotFound
              raise NotPublished, "#{url} does not exist."
            when Net::HTTPServerError, Net::HTTPTooManyRequests
              raise Transient, "#{url} answered #{response.code} #{response.message}."
            else
              raise DownloadFailed, "#{url} answered #{response.code} #{response.message}."
            end
          end
        end
      end
    end

    module_function

    # Unpacks with the argv Packaging.extract_command chose. Outside any bundle,
    # because pwsh and tar have no use for this process's RUBYOPT.
    def run_extract(argv)
      launch = -> { system(*argv.map(&:to_s)) }
      ok = defined?(Bundler) ? Bundler.with_unbundled_env(&launch) : launch.call
      raise DownloadFailed, "Unpacking failed: #{Packaging.to_shell(argv)}" unless ok
    end

    def default_log
      ->(message) { puts message }
    end

    # The interpreter for `triple` from release `version`, unpacked so that
    # `into`/bin/ruby exists. Nothing appears at `into` unless the checksum
    # matched and the archive held an interpreter: it is unpacked beside `into`
    # and renamed into place, so an interrupted download cannot leave behind a
    # directory that runtime_dir would mistake for a working Ruby.
    def install_runtime(into:, triple:, version:, base_url:, fetcher: HttpFetcher.new,
                        extract: method(:run_extract), log: default_log)
      into = Pathname.new(into.to_s)
      if into.exist? && !(into.directory? && into.empty?)
        raise DownloadFailed, <<~MSG
          #{into} already exists and holds no interpreter, so nothing was downloaded
          over it. Delete it and run the task again.
        MSG
      end

      FileUtils.mkdir_p(into.dirname)
      Dir.mktmpdir(".runtime-download-", into.dirname.to_s) do |work|
        name = Packaging.runtime_asset_name(version: version, triple: triple)
        archive = download_verified(name, version: version, base_url: base_url,
                                          fetcher: fetcher, workdir: work, log: log)

        staging = File.join(work, "unpacked")
        FileUtils.mkdir_p(staging)
        log.call("Unpacking #{name}")
        extract.call(Packaging.extract_command(archive, into: staging, triple: triple))

        root = File.join(staging, Packaging::RUNTIME_ARCHIVE_ROOT)
        unless Packaging.runtime?(root)
          raise DownloadFailed,
                "#{name} has no #{Packaging::RUNTIME_ARCHIVE_ROOT}/bin/ruby inside it, so it is not a runtime archive."
        end

        FileUtils.rmdir(into) if into.directory?
        File.rename(root, into.to_s)
      end
      into
    end

    # The shell binary for `triple` from release `version`, written to `into`
    # and made executable. Downloaded beside its destination and renamed, for
    # the same reason as the runtime.
    def install_shell(into:, triple:, version:, base_url:, fetcher: HttpFetcher.new, log: default_log)
      into = Pathname.new(into.to_s)
      FileUtils.mkdir_p(into.dirname)
      Dir.mktmpdir(".shell-download-", into.dirname.to_s) do |work|
        name = Packaging.shell_asset_name(version: version, triple: triple)
        path = download_verified(name, version: version, base_url: base_url,
                                       fetcher: fetcher, workdir: work, log: log)
        FileUtils.chmod(0o755, path)
        # Windows will not rename over an existing file.
        FileUtils.rm_f(into)
        File.rename(path, into.to_s)
      end
      into
    end

    # SHA256SUMS first, then the asset, then the comparison. The checksum file
    # is what tells a release that does not exist apart from a platform the
    # release does not carry, and both from a download that went wrong.
    def download_verified(name, version:, base_url:, fetcher:, workdir:, log:)
      sums_url = Packaging.release_asset_url(Packaging::CHECKSUMS_ASSET, version: version, base_url: base_url)
      sums_path = File.join(workdir, Packaging::CHECKSUMS_ASSET)
      begin
        fetcher.call(sums_url, sums_path)
      rescue NotPublished
        raise NotPublished, "No release #{Packaging.release_tag(version)} is published at #{base_url} " \
                            "(#{sums_url} does not exist)."
      end
      expected = Packaging.expected_checksum!(Packaging.parse_checksums(File.read(sums_path)), name)

      url = Packaging.release_asset_url(name, version: version, base_url: base_url)
      log.call("Downloading #{url}")
      path = File.join(workdir, name)
      fetcher.call(url, path)
      Packaging.verify_checksum!(path, expected, name: name)
      log.call("  SHA256 verified: #{expected}")
      path
    end
  end
end

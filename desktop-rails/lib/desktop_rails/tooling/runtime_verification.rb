# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "desktop_rails/tooling"

module DesktopRails
  module Tooling
    # Does an interpreter actually relocate, and does it still work?
    #
    # "It compiled" is not the claim, and neither is "it downloaded". The claim
    # is that it runs from a path it was not built for, with nothing pointing at
    # a package manager. So the interpreter is copied somewhere new first and
    # every question is asked of the copy.
    #
    # One check for every platform. Windows used to have its own shorter list in
    # PowerShell and another inside DesktopRails::Packaging, and each fix landed
    # in one of the three.
    class RuntimeVerification
      Check = Struct.new(:description, :ok, :detail, keyword_init: true)

      # Libraries a package manager installs, by the prefixes they live under.
      # A shipped binary linking any of them works on the build machine and
      # nowhere else.
      PACKAGE_MANAGER_LINKS = {
        macos: %r{/opt/homebrew|/usr/local/(opt|Cellar)},
        linux: %r{/home/linuxbrew|/usr/local/lib/lib(ssl|crypto|yaml)}
      }.freeze

      # OpenSSL::OPENSSL_VERSION is a compile-time constant: it reports the
      # version the extension was *built* against even when a different library
      # is what loads. So do real work with it — a digest, an HMAC and a cipher
      # all go through symbols that differ between versions, which is exactly how
      # a mismatched system library shows itself.
      OPENSSL_PROBE = <<~'RUBY'
        require "openssl"
        raise "digest" unless OpenSSL::Digest::SHA256.hexdigest("x").length == 64
        raise "hmac" unless OpenSSL::HMAC.hexdigest("SHA256", "k", "m").length == 64
        c = OpenSSL::Cipher.new("aes-256-gcm").encrypt
        c.key = "0" * 32
        raise "cipher" if c.random_iv.empty?
        print "#{OpenSSL::OPENSSL_VERSION} | runtime #{OpenSSL::OPENSSL_LIBRARY_VERSION}"
      RUBY

      PSYCH_PROBE = 'require "psych"; exit(Psych.load("- 1") == [1] ? 0 : 1)'

      CORE_EXTENSIONS_PROBE = 'require "zlib"; require "json"; require "socket"; require "fiddle"'

      # Compared as files rather than as strings: a prefix may be spelled with
      # 8.3 short names on Windows or through /private on macOS and still be the
      # same directory. Checking that the prefix merely contained "relocated"
      # held for the path this class chose and proved less than it seemed.
      RELOCATION_PROBE = <<~'RUBY'
        expected = ENV.fetch("DESKTOP_RAILS_RELOCATED_RUBY")
        actual = File.join(RbConfig::CONFIG["bindir"], File.basename(expected))
        exit(File.exist?(actual) && File.identical?(actual, expected) ? 0 : 1)
      RUBY

      def initialize(runtime, host_os: RbConfig::CONFIG["host_os"], runner: Command.new, log: $stdout)
        @runtime = File.expand_path(runtime.to_s)
        @host_os = host_os.to_s
        @runner = runner
        @log = log
      end

      def platform
        Tooling.platform(@host_os)
      end

      def ruby_name
        platform == :windows ? "ruby.exe" : "ruby"
      end

      # The tool that lists what a binary links, or nil where there is no such
      # question to ask: a Windows interpreter resolves its DLLs beside itself.
      def linkage_argv(binary)
        case platform
        when :macos then [ "otool", "-L", binary ]
        when :linux then [ "ldd", binary ]
        end
      end

      def self.binary?(path)
        name = File.basename(path)
        name == "ruby" || name.end_with?(".so", ".bundle", ".dylib")
      end

      # Every loadable binary under dir, which is what the linkage check reads.
      def self.binaries_in(dir)
        found = []
        Find.find(dir) do |path|
          found << path if File.file?(path) && !File.symlink?(path) && binary?(path)
        end
        found.sort
      end

      # The lines of otool or ldd output that name a package manager's library.
      def self.package_manager_links(output, platform)
        pattern = PACKAGE_MANAGER_LINKS[platform]
        return [] unless pattern

        output.to_s.lines.map(&:strip).select { |line| line.match?(pattern) }
      end

      # "OpenSSL 3.5.4 30 Sep 2025 | runtime OpenSSL 3.5.4 30 Sep 2025" into
      # the two versions, or nil when the probe printed something else.
      def self.parse_openssl(output)
        built, runtime = output.to_s.strip.split(" | runtime ", 2)
        return nil if built.nil? || runtime.nil? || built.empty? || runtime.empty?

        [ built, runtime ]
      end

      def verify!
        passed = verify
        raise CheckFailed, "#{@runtime} is not a relocatable runtime; see the failures above." unless passed

        true
      end

      # Prints each check as it runs and returns whether all of them passed.
      def verify
        unless File.file?(File.join(@runtime, "bin", ruby_name))
          fail_check("#{@runtime} has no bin/#{ruby_name}")
          finish(false)
          return false
        end

        scratch = Dir.mktmpdir("desktop-rails-verify-")
        moved = File.join(scratch, "relocated", "ruby")
        FileUtils.mkdir_p(File.dirname(moved))
        FileUtils.cp_r(@runtime, moved)

        results = checks(moved).map do |check|
          check.ok ? pass_check(check.description) : fail_check(check.description, check.detail)
          check.ok
        end
        finish(results.all?)
      ensure
        FileUtils.rm_rf(scratch) if scratch
      end

      private

      def checks(moved)
        Enumerator.new do |y|
          ruby = File.join(moved, "bin", ruby_name)

          y << linkage_check(moved)

          y << probe_check(ruby, [ "-v" ], "runs from the new path", "will not run after being moved")
          y << probe_check(ruby, [ "-e", PSYCH_PROBE ],
                           "psych loads and parses — Rails cannot boot without it", "psych failed")

          openssl = @runner.capture([ ruby, "-e", OPENSSL_PROBE ], clean_ruby: true)
          versions = openssl.success? && self.class.parse_openssl(openssl.output)
          if versions
            y << Check.new(description: "openssl does real work (#{openssl.output.strip})", ok: true)
            built, loaded = versions
            # The two versions disagreeing means the extension is loading a
            # library it was not built against, which is the failure this whole
            # check exists to catch.
            y << Check.new(description: built == loaded ? "built and runtime OpenSSL agree" :
                             "built against #{built} but loading #{loaded} — a system library is winning",
                           ok: built == loaded)
          else
            y << Check.new(description: "openssl failed: #{openssl.output.lines.first(2).join(" ").strip}", ok: false)
          end

          y << probe_check(ruby, [ "-e", CORE_EXTENSIONS_PROBE ],
                           "zlib, json, socket, fiddle all load", "a core extension failed")
          y << probe_check(ruby, [ "-e", RELOCATION_PROBE ],
                           "RbConfig follows the binary (--enable-load-relative works)",
                           "RbConfig still points at the build prefix",
                           env: { "DESKTOP_RAILS_RELOCATED_RUBY" => ruby })
        end
      end

      def linkage_check(moved)
        return Check.new(description: "linkage not inspected on #{platform}; DLLs resolve beside the interpreter", ok: true) unless linkage_argv(moved)

        bad = self.class.binaries_in(moved).flat_map do |binary|
          output = @runner.capture(linkage_argv(binary)).output
          self.class.package_manager_links(output, platform).map { |line| "#{File.basename(binary)}: #{line}" }
        end
        if bad.empty?
          Check.new(description: "nothing links into a package manager", ok: true)
        else
          Check.new(description: "package-manager linkage:", ok: false, detail: bad.first(5))
        end
      end

      def probe_check(ruby, args, success, failure, env: {})
        ok = @runner.capture([ ruby, *args ], env: env, clean_ruby: true).success?
        Check.new(description: ok ? success : failure, ok: ok)
      end

      def pass_check(message)
        @log.puts "  \e[32m✓\e[0m #{message}"
      end

      def fail_check(message, detail = nil)
        @log.puts "  \e[31m✗\e[0m #{message}"
        Array(detail).each { |line| @log.puts "      #{line}" }
      end

      def finish(ok)
        @log.puts(ok ? "  \e[32mPASS\e[0m" : "  \e[31mFAIL\e[0m")
        ok
      end
    end
  end
end

# frozen_string_literal: true

require "fileutils"
require "desktop_rails/tooling"

module DesktopRails
  module Tooling
    # Removes what an end user's machine will never read.
    #
    # A shipped bundle carries a lot that only a build machine needs: static
    # archives left over from linking, the .gem files RubyGems keeps after
    # installing, headers for compiling extensions that are already compiled,
    # debug symbols, generated documentation, and each gem's own test suite.
    #
    # The packers boot the app after pruning, because "smaller" is worthless if
    # it also means "broken".
    #
    # One implementation for every platform. The Windows copy of this used to
    # hard-code the gem directory for Ruby 3.4.0 and skip documentation, and
    # nobody noticed, because the two copies were never read side by side.
    class Prune
      # Directories that are a gem's own tests, but only at each gem's root. A
      # bare `test` anywhere also matches rack-test's lib/rack/test/, which is
      # library code, and the app then fails to boot.
      GEM_TEST_DIRECTORIES = %w[test spec features].freeze
      DOC_DIRECTORIES = %w[ri rdoc].freeze

      Plan = Struct.new(:static_archives, :gem_caches, :headers, :debug_symbols, :docs,
                        :gem_test_suites, :strippable, keyword_init: true) do
        def removals
          static_archives + gem_caches + headers + debug_symbols + docs + gem_test_suites
        end
      end

      attr_reader :root

      def initialize(root, keep_dev: false, host_os: RbConfig::CONFIG["host_os"], runner: Command.new, log: $stdout)
        @root = File.expand_path(root.to_s)
        @keep_dev = keep_dev
        @host_os = host_os.to_s
        @runner = runner
        @log = log
      end

      def keep_dev?
        @keep_dev
      end

      # The gems/ directories whose immediate children are installed gems: the
      # app's own set, and the runtime's default gems for any ABI version.
      def gem_roots
        [ File.join(root, "gems", "gems"), *Dir.glob(File.join(root, "ruby", "lib", "ruby", "gems", "*", "gems")) ]
          .select { |dir| File.directory?(dir) }
      end

      # Everything this would remove and strip, decided without touching a file.
      def plan
        plan = Plan.new(static_archives: [], gem_caches: [], headers: [], debug_symbols: [], docs: [],
                        gem_test_suites: [], strippable: [])
        return plan unless File.directory?(root)

        headers = File.join(root, "ruby", "include")
        roots = gem_roots

        Find.find(root) do |path|
          stat = File.lstat(path)
          name = File.basename(path)

          if stat.directory?
            if path == headers
              plan.headers << path
            elsif name.end_with?(".dSYM")
              plan.debug_symbols << path
            elsif !keep_dev? && DOC_DIRECTORIES.include?(name)
              plan.docs << path
            elsif !keep_dev? && GEM_TEST_DIRECTORIES.include?(name) && roots.include?(File.dirname(path, 2))
              plan.gem_test_suites << path
            else
              next
            end
            # Nothing inside a directory being removed needs a decision of its own.
            Find.prune
          elsif stat.file?
            if name.end_with?(".a")
              plan.static_archives << path
            elsif name.end_with?(".gem")
              plan.gem_caches << path
            elsif strippable?(path)
              plan.strippable << path
            end
          end
        end
        plan
      end

      # Symbols are stripped from the interpreter and the loadable extensions.
      # Apple's strip regenerates the ad-hoc linker signature on arm64, so this
      # does not invalidate anything — and the real codesign pass happens after
      # it, which settles it either way. Windows binaries are left alone: there
      # is no strip there to trust.
      def strippable?(path)
        return false if Tooling.windows?(@host_os)

        name = File.basename(path)
        name.end_with?(".bundle", ".dylib") || (name == "ruby" && File.basename(File.dirname(path)) == "bin")
      end

      def strip_argv(path)
        [ "strip", "-S", "-x", path ]
      end

      def run!
        before = Tooling.size_of(root)
        plan = self.plan

        report "static archives (.a)", remove(plan.static_archives)
        report ".gem cache", remove(plan.gem_caches)
        report "ruby/include", remove(plan.headers)
        report "dSYM bundles", remove(plan.debug_symbols)
        report "docs and gem test suites", remove(plan.docs + plan.gem_test_suites) unless keep_dev?

        @log.puts format("  %-30s %s", "stripped binaries", strip(plan.strippable)) unless plan.strippable.empty?

        after = Tooling.size_of(root)
        @log.puts "  ─────────────────────────────────────"
        @log.puts format("  %-30s %sM -> %sM  (saved %sM)", "total",
                         Tooling.megabytes(before), Tooling.megabytes(after), Tooling.megabytes(before - after))
        plan
      end

      private

      # How many were stripped. A file strip refuses is left as it is, as the
      # shell script did: an unstripped binary is only larger.
      def strip(paths)
        return "none: no strip on PATH" unless Tooling.which("strip")

        paths.count { |path| @runner.capture(strip_argv(path)).success? }
      end

      def remove(paths)
        bytes = paths.sum { |path| Tooling.size_of(path) }
        paths.each { |path| FileUtils.rm_rf(path) }
        [ paths.size, bytes ]
      end

      def report(label, (count, bytes))
        @log.puts format("  %-30s %s", label, count.zero? ? "none" : "#{count} removed, #{Tooling.megabytes(bytes)}M")
      end
    end
  end
end

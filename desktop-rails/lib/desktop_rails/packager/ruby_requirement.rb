# frozen_string_literal: true

require "pathname"
require "desktop_rails/packager"

module DesktopRails
  module Packager
    # Makes the packed copy of an app accept the Ruby the package carries, or
    # refuses to package it when that Ruby cannot be what the app asks for.
    #
    # A Gemfile's `ruby "4.0.6"` — which `rails new` writes for 7.0 and 7.1, and
    # which many apps pin by hand or read from .ruby-version — records the
    # developer's Ruby. Inside the package Bundler compares it with the runtime's
    # and refuses to load anything: "Your Ruby version is 4.0.7, but your Gemfile
    # specified 4.0.6", at launch, on the user's machine. A patch release keeps
    # the language and the extension ABI, so such a pin is not a reason the app
    # cannot run.
    #
    # So, in the packed copy only, as with path gems:
    #
    #   * a requirement the runtime already meets is left as it is;
    #   * one that differs only in the patch release is replaced with the
    #     runtime's exact version, and said so;
    #   * anything else — `~> 3.4`, `< 4`, another engine — is a requirement the
    #     runtime cannot meet, and packaging stops with both versions named,
    #     before a bundle is built that could never start.
    #
    # Gemfile.lock's RUBY VERSION is set to the runtime's as well, so the lock
    # describes the Ruby that will read it.
    class RubyRequirement
      DIRECTIVE = /^[ \t]*ruby[ \t(]/

      # The `ruby` calls a Gemfile makes, read the way Bundler reads them: by
      # evaluating the Gemfile, since `ruby File.read(".ruby-version").strip`
      # is as common as a literal. Everything else a Gemfile says is ignored,
      # and none of it runs: `gem` in particular is Kernel#gem outside Bundler,
      # which would try to activate the gem in this process.
      class Reader
        Call = Struct.new(:versions, :options, keyword_init: true)

        attr_reader :calls

        def initialize(gemfile)
          @gemfile = gemfile.to_s
          @calls = []
        end

        def read
          Dir.chdir(File.dirname(@gemfile)) do
            instance_eval(File.read(@gemfile), @gemfile, 1)
          end
          calls
        end

        def ruby(*versions, **options)
          versions = versions.flatten.map(&:to_s)
          if (file = options[:file])
            content = File.read(File.expand_path(file.to_s, File.dirname(@gemfile)))
            # .tool-versions says "ruby 4.0.7"; .ruby-version says "4.0.7" or
            # "ruby-4.0.7".
            versions = [ (content[/^ruby\s+(\S+)/, 1] || content.strip).delete_prefix("ruby-") ]
          end
          @calls << Call.new(versions: versions, options: options)
          nil
        end

        %i[source gem group platforms platform path git github gemspec plugin install_if env
           git_source eval_gemfile].each do |name|
          define_method(name) { |*_args, **_options| nil }
        end

        def method_missing(_name, *_args, **_options)
          nil
        end

        def respond_to_missing?(_name, _include_private = false)
          true
        end
      end

      attr_reader :runtime_version

      def initialize(packed:, runtime_version:, runtime_patchlevel: nil, log: ->(message) { puts message })
        @packed = Pathname.new(File.expand_path(packed.to_s))
        @runtime_version = Gem::Version.new(runtime_version.to_s)
        @runtime_patchlevel = runtime_patchlevel
        @log = log
      end

      def gemfile
        @packed.join("Gemfile")
      end

      def lockfile
        @packed.join("Gemfile.lock")
      end

      # What the packed Gemfile requires, or nil when it names no Ruby.
      def requirements
        return nil unless gemfile.exist?

        directives = gemfile.read.lines.grep(DIRECTIVE)
        return nil if directives.empty?
        # `ruby RUBY_VERSION` asks for whichever Ruby reads the Gemfile, which
        # inside the package is the runtime. Evaluated here it would be the
        # developer's Ruby instead, and could refuse a package that runs.
        return nil if directives.all? { |line| line.include?("RUBY_VERSION") }

        calls = begin
          Reader.new(gemfile).read
        rescue StandardError, ScriptError => e
          raise InvalidInput, "The Gemfile names a Ruby version, and reading it failed: #{e.class}: #{e.message}. " \
                              "Packaging needs to know which Ruby the app asks for, to check the runtime is one."
        end
        calls.empty? ? nil : calls
      end

      # Whether the Gemfile has to be rewritten for the runtime: false when it
      # names no Ruby or one the runtime already is. Raises, naming both
      # versions, when no rewrite could make them agree. Reads the Gemfile and
      # changes nothing, so it can be asked of the developer's own app.
      def rewrite_needed?
        calls = requirements
        return false if calls.nil? || calls.all? { |call| met?(call) }

        calls.each { |call| check!(call) }
        true
      end

      def apply!
        rewrite_gemfile!(requirements) if rewrite_needed?
        rewrite_lockfile!
        self
      end

      def requirement_for(call)
        Gem::Requirement.new(*(call.versions.empty? ? [ ">= 0" ] : call.versions))
      end

      def met?(call)
        engine_ok?(call) && requirement_for(call).satisfied_by?(runtime_version)
      end

      # The same requirement with every pin moved from a patch release to its
      # series: "4.0.6", "4.0" and "~> 4.0.6" become "~> 4.0.0", ">= 4.0.9" becomes
      # ">= 4.0.0". Upper bounds and exclusions stay exactly as written.
      def loosened(call)
        Gem::Requirement.new(*requirement_for(call).requirements.map do |op, version|
          segments = version.segments
          if (op == "=" && segments.size >= 2) || (%w[~> >=].include?(op) && segments.size >= 3)
            series = Gem::Version.new("#{segments[0]}.#{segments[1]}.0")
            [ op == ">=" ? ">=" : "~>", series ]
          else
            [ op, version ]
          end
        end.map { |op, version| "#{op} #{version}" })
      end

      private

      def engine_ok?(call)
        engine = call.options[:engine]
        engine.nil? || engine.to_s == "ruby"
      end

      def check!(call)
        unless engine_ok?(call)
          raise InvalidInput, "The Gemfile asks for #{call.options[:engine]} #{call.options[:engine_version]}".rstrip +
                              ", and the runtime being packaged is CRuby #{runtime_version}. A packaged app runs " \
                              "on that runtime, so the app cannot be packaged with it."
        end
        return if met?(call) || loosened(call).satisfied_by?(runtime_version)

        described = call.versions.empty? ? "any version" : call.versions.join(", ")
        raise InvalidInput, <<~MSG.strip
          The Gemfile requires Ruby #{described}, and the runtime being packaged is Ruby #{runtime_version}.

          A packaged app runs on the Ruby it carries, and #{runtime_version} is not in that range. Only a
          difference in the patch release is accepted for you. Either change the requirement in the
          Gemfile, or package with a runtime whose Ruby meets it (DESKTOP_RAILS_RUNTIME).
        MSG
      end

      def rewrite_gemfile!(calls)
        text = gemfile.read
        replaced = 0
        lines = text.lines
        index = 0
        while index < lines.size
          if lines[index].match?(DIRECTIVE)
            first = index
            # A directive continued onto further lines, by a trailing comma or
            # backslash, is replaced as a whole.
            index += 1 while index < lines.size - 1 && lines[index].rstrip.end_with?(",", "\\")
            original = lines[first..index].map(&:strip).join(" ")
            indent = lines[first][/\A[ \t]*/]
            newline = lines[index].end_with?("\r\n") ? "\r\n" : "\n"
            lines[first..index] = [
              "#{indent}# desktop-rails: was `#{original}`; the packaged app runs on the Ruby it carries.#{newline}",
              "#{indent}ruby \"#{runtime_version}\"#{newline}"
            ]
            index = first + 2
            replaced += 1
          else
            index += 1
          end
        end
        gemfile.write(lines.join)
        @log.call("  Ruby requirement: the packed Gemfile now asks for #{runtime_version}, the runtime's " \
                  "(was #{calls.map { |call| call.versions.join(", ") }.join("; ")})") if replaced.positive?
      end

      def rewrite_lockfile!
        return unless lockfile.exist?

        lock = lockfile.read
        rewritten = lock.sub(/^(RUBY VERSION\r?\n[ \t]+ruby )(\S+?)(p-?\d+)?(\r?)$/) do
          suffix = $3 && @runtime_patchlevel ? "p#{@runtime_patchlevel}" : ""
          "#{$1}#{runtime_version}#{suffix}#{$4}"
        end
        return if rewritten == lock

        lockfile.write(rewritten)
        @log.call("  Ruby requirement: Gemfile.lock records #{runtime_version}, the runtime's")
      end
    end
  end
end

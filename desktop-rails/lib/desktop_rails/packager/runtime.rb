# frozen_string_literal: true

require "desktop_rails/packager"

module DesktopRails
  module Packager
    # The relocatable interpreter a bundled package carries, described from its
    # files rather than by running it.
    #
    # Reading rbconfig.rb means a Windows runtime can be packaged, and its
    # launcher written, on a Mac or in a test, and that nothing about the
    # version depends on which Ruby happens to be running the packager. That
    # Ruby is the developer's, and the difference between the two is the whole
    # reason RubyRequirement exists.
    class Runtime
      attr_reader :dir

      def initialize(dir)
        @dir = File.expand_path(dir.to_s)
      end

      def interpreter
        %w[ruby.exe ruby].map { |exe| File.join(dir, "bin", exe) }.find { |path| File.file?(path) }
      end

      def valid?
        !interpreter.nil?
      end

      # "4.0.7": what RUBY_VERSION is inside the packaged app. From MAJOR,
      # MINOR and TEENY, because RUBY_PROGRAM_VERSION is written there as a
      # make variable rather than a value.
      def version
        %w[MAJOR MINOR TEENY].map { |key| config_value(key) }.join(".")
      end

      # "4.0.0": the ABI directory its default gems live under,
      # lib/ruby/gems/<abi>. Named for the minor series, so it changes with
      # the Ruby a runtime carries and must never be written down.
      def abi
        config_value("ruby_version")
      end

      def patchlevel
        config_value("PATCHLEVEL")
      end

      def rbconfig_path
        @rbconfig_path ||= Dir.glob(File.join(dir, "lib", "ruby", "*", "*", "rbconfig.rb")).min
      end

      private

      def config_value(key)
        unless rbconfig_path
          raise InvalidInput, "#{dir} has no lib/ruby/<version>/<platform>/rbconfig.rb, so it is not a Ruby " \
                              "installation this can package. Point at the runtime desktop:runtime installs."
        end

        @config ||= File.read(rbconfig_path)
        value = @config[/^\s*CONFIG\["#{Regexp.escape(key)}"\]\s*=\s*"([^"]*)"/, 1]
        raise InvalidInput, "#{rbconfig_path} does not say what #{key} is." unless value

        value
      end
    end
  end
end

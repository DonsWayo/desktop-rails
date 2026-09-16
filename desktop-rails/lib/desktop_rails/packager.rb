# frozen_string_literal: true

require "desktop_rails/packager/archive"
require "desktop_rails/packager/layout"
require "desktop_rails/packager/mac_app"
require "desktop_rails/packager/linux_tree"
require "desktop_rails/packager/windows_tree"

module DesktopRails
  # Assembling what a person downloads, in Ruby, one code path for every
  # platform.
  #
  # Each platform's shape is a layout: where the executable goes, where its
  # desktop-rails.config.json goes (the shell looks in the resource directory
  # and beside itself), what makes the directory an application to the desktop
  # (Info.plist and a signature, a .desktop entry), and the archive it is handed
  # out as. Hosted packaging (DesktopRails::HostedPackage) fills a layout with
  # the shell and a config. The bundled packers under packaging/ still do their
  # own assembly in bash and PowerShell; they are meant to move onto these same
  # layouts, adding the interpreter, the gems and the app to the resource
  # directory, so that there is one definition of what a package looks like.
  #
  # Layouts decide and write files. Anything that needs another program —
  # codesign, sips — goes through a runner, a callable that takes argv and
  # answers whether it succeeded, so tests can build every platform's layout on
  # any machine and see exactly which commands would have run.
  module Packager
    CONFIG_FILENAME = "desktop-rails.config.json"

    # Another program the package needed, such as codesign, did not succeed.
    class CommandFailed < StandardError; end

    # Something handed to a layout it cannot use, such as an icon format the
    # platform has no place for.
    class InvalidInput < StandardError; end

    module_function

    def layout_for(platform, **options)
      case platform.to_sym
      when :macos then MacApp.new(**options)
      when :linux then LinuxTree.new(**options)
      when :windows then WindowsTree.new(**options)
      else raise ArgumentError, "No package layout for #{platform}"
      end
    end

    # The directory and file name a package takes from its display name: lower
    # case, anything but letters and digits turned into single dashes. For
    # "Acme Assistant" that is what the bundled packers produce too; for a name
    # with punctuation it keeps characters out of file names that a .desktop
    # Exec line or a shell would need quoted.
    def slug(name)
      slug = name.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      slug.empty? ? "app" : slug
    end

    # Runs argv with no shell in between and outside this process's bundle,
    # for the same reasons desktop.rake's own runner does: a path with a space
    # cannot split, and a Bundler-loaded parent's RUBYOPT must not leak into
    # tools that have no use for it.
    def system_runner
      lambda do |argv|
        launch = -> { system(*argv.map(&:to_s)) }
        defined?(Bundler) ? Bundler.with_unbundled_env(&launch) : launch.call
      end
    end
  end
end

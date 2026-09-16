# frozen_string_literal: true

require "find"
require "rbconfig"
require "desktop_rails/paths"

module DesktopRails
  # The build-machine side of desktop-rails: compiling and checking the
  # relocatable interpreter, pruning a bundle, disk images, notarisation,
  # signing updates, and the checks CI runs against a packaged app.
  #
  # It used to be bash, PowerShell and Python under packaging/, and that cost
  # twice. The bash and PowerShell copies of the same step drifted apart, which
  # is where most Windows bugs came from, and none of it could ship in this gem,
  # because RubyGems only packages files beneath the gem's own root. A Ruby
  # framework can assume Ruby, so every step is a class here with one code path
  # for every platform, and exe/desktop-rails-tool is the command line over them.
  #
  # Nothing here needs Rails, ActiveSupport or a bundle. CI runs it with whatever
  # Ruby the runner has, and the packed interpreter can run it too.
  #
  # Each class separates what it decides — argv, which files, what an output
  # means — from what it does, and takes the process runner as an argument, so
  # the decisions are tested without a compiler, a certificate or a GUI.
  #
  # What a package looks like is DesktopRails::Packager's, not this module's:
  # its layouts assemble the .app and the trees, and run programs through the
  # same Command. The bundled packers still under packaging/ are meant to move
  # onto those layouts, calling Prune, RuntimeVerification and the Notarization
  # and DiskImage steps here.
  module Tooling
    class Error < StandardError; end

    # Something the step needs is not on this machine. The message always says
    # what, and what to do about it.
    class MissingPrerequisite < Error; end

    # A check that ran and found something wrong. Distinct from a command that
    # could not run at all, so a caller can tell "broken runtime" from "no
    # otool".
    class CheckFailed < Error; end

    # The repository this gem sits in, when it sits in one. Some inputs are not
    # part of the gem yet — the minisign implementation and the entitlements
    # file are shared with the shell scripts that still pack apps — and are
    # found here until those scripts move into the gem as well.
    CHECKOUT_ROOT = File.expand_path("../../..", __dir__)

    module_function

    def checkout_file(*parts)
      path = File.join(CHECKOUT_ROOT, *parts)
      File.exist?(path) ? path : nil
    end

    # The path of the command line, for callers that run a step as a separate
    # process — the rake tasks, which must not share Bundler's environment with
    # an interpreter they are checking.
    def executable
      File.expand_path("../../exe/desktop-rails-tool", __dir__)
    end

    def platform(host_os = RbConfig::CONFIG["host_os"])
      Paths.platform(host_os)
    end

    def windows?(host_os = RbConfig::CONFIG["host_os"])
      platform(host_os) == :windows
    end

    # Bytes under a path, without following symbolic links, as `du` counts.
    def size_of(path)
      return 0 unless File.exist?(path) || File.symlink?(path)

      total = 0
      Find.find(path) do |entry|
        stat = File.lstat(entry)
        total += stat.size if stat.file?
      rescue SystemCallError
        next
      end
      total
    end

    def megabytes(bytes)
      (bytes / 1024.0 / 1024.0).round
    end

    def human_size(bytes)
      units = %w[B K M G]
      size = bytes.to_f
      unit = units.shift
      while size >= 1024 && !units.empty?
        size /= 1024
        unit = units.shift
      end
      unit == "B" ? "#{bytes}B" : format("%.1f%s", size, unit)
    end

    # An executable on PATH, or nil. Written out rather than asking a shell,
    # because `which` is not on Windows and `where` is not anywhere else.
    def which(name, env: ENV, host_os: RbConfig::CONFIG["host_os"])
      extensions = windows?(host_os) ? [ ".exe", ".cmd", ".bat", "" ] : [ "" ]
      env["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
        next if dir.empty?

        extensions.each do |ext|
          candidate = File.join(dir, "#{name}#{ext}")
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
      end
      nil
    end
  end
end

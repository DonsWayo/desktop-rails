# frozen_string_literal: true

# Stop the Windows interpreter in a packaged app writing into its own tree.
#
# RubyInstaller's rubygems/defaults/operating_system.rb runs every time
# RubyGems loads, so on every launch of the app. Its first act is to create and
# delete a file called writable_p in Gem.default_dir, which is inside the
# bundle, to decide whether `gem install` should default to a per-user
# directory. The Windows GUI job found it: nothing else a packaged app does
# touches the tree, and this did so on each start.
#
# A packaged app never installs a gem, so the answer to that question does not
# matter, but the write does: an app installed under C:\Program Files cannot
# write there, and a tree that behaves differently depending on where it was
# unpacked is harder to reason about than one that does not. So the probe is
# replaced by the answer a read-only install gets, EACCES, and every copy of the
# app takes the same branch whether or not its directory happens to be
# writable. The rest of the file — the DLL search paths especially — is left
# exactly as RubyInstaller wrote it.
#
# This rewrites the COPY of the interpreter inside the bundle, never the
# runtime it was copied from.
#
# Usage: ruby windows-runtime-readonly.rb <interpreter dir inside the bundle>

module WindowsRuntimeReadonly
  PROBE = %r{
    ^(?<indent>[ \t]*)checkfile\s*=\s*File\.join\(Gem\.default_dir,\s*"/writable_p"\)[ \t]*\r?\n
    [ \t]*File\.write\(checkfile,\s*""\)[ \t]*\r?\n
    [ \t]*File\.unlink\(checkfile\)[^\r\n]*\r?\n
  }x

  REPLACEMENT = <<~RUBY
    # desktop-rails: a packaged app never writes into its own interpreter, so
    # it takes the branch a read-only install takes instead of probing with a
    # file. See packaging/windows-runtime-readonly.rb.
    raise Errno::EACCES, "a packaged app's interpreter is read-only"
  RUBY

  class UnknownLayout < StandardError; end

  module_function

  # The file's new source, or nil when there is nothing to change. Raises when
  # the file still probes in a way this does not recognise, so a new
  # RubyInstaller release is noticed at packaging time rather than as a write
  # inside every installed app.
  def rewrite(source)
    return nil unless source.include?("writable_p")

    match = PROBE.match(source)
    unless match
      raise UnknownLayout, "operating_system.rb still mentions writable_p, but not in the shape this knows how to disable"
    end

    newline = match[0].include?("\r\n") ? "\r\n" : "\n"
    replacement = REPLACEMENT.lines.map { |line| "#{match[:indent]}#{line.chomp}#{newline}" }.join
    source.sub(PROBE) { replacement }
  end

  def files(runtime)
    # RubyInstaller installs it under lib/ruby/<ABI>; site_ruby is where
    # RubyGems would also find one. expand_path because the packer passes a
    # Windows path, and in a glob pattern its backslashes are escapes: the
    # first run of this found nothing and said so.
    root = File.expand_path(runtime)
    Dir.glob(File.join(root, "lib", "ruby", "{site_ruby/*,*}", "rubygems", "defaults", "operating_system.rb")).uniq
  end

  def apply(runtime)
    files(runtime).filter_map do |file|
      rewritten = rewrite(File.binread(file))
      next unless rewritten

      File.binwrite(file, rewritten)
      file
    end
  end
end

if $PROGRAM_NAME == __FILE__
  runtime = ARGV.first || abort("usage: windows-runtime-readonly.rb <interpreter dir inside the bundle>")
  begin
    changed = WindowsRuntimeReadonly.apply(runtime)
  rescue WindowsRuntimeReadonly::UnknownLayout => e
    abort "  #{e.message}"
  end
  puts(changed.empty? ? "  no gem writability probe to disable" : "  gem writability probe disabled in #{changed.size} file(s)")
end

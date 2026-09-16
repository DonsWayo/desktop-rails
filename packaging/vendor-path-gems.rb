# frozen_string_literal: true
#
# Copy an app's path gems into the bundle and point its Gemfile at the copies.
#
# A Gemfile's `path:` is relative to where the app was developed. Inside a
# packaged bundle the app sits somewhere else, so the path points at nothing and
# the app dies at boot with Bundler::PathError. Path gems are ordinary — local
# engines, monorepo gems, and anything not yet published — so this is not a
# corner case.
#
# This rewrites the COPY of the app inside the bundle, never the developer's own
# Gemfile. Each path source named in Gemfile.lock is copied into
# vendor/path-gems/<name>, and both Gemfile.lock and Gemfile are pointed there.
#
# Usage: ruby vendor-path-gems.rb <original app dir> <app dir inside the bundle>

require "fileutils"
require "pathname"

original, packed = ARGV.map { |p| Pathname.new(p).expand_path }
abort "usage: vendor-path-gems.rb <original app> <packed app>" unless original && packed

lockfile = packed.join("Gemfile.lock")
gemfile  = packed.join("Gemfile")
exit 0 unless lockfile.exist?

lock = lockfile.read
remotes = lock.scan(/^PATH\n  remote: (.+)$/).flatten.uniq
if remotes.empty?
  puts "  no path gems"
  exit 0
end

vendor = packed.join("vendor", "path-gems")
FileUtils.mkdir_p(vendor)

remotes.each do |remote|
  # Resolved against the ORIGINAL app, which is where the relative path meant
  # something.
  source = (Pathname.new(remote).absolute? ? Pathname.new(remote) : original.join(remote)).expand_path
  abort "  path gem #{remote} resolves to #{source}, which does not exist" unless source.directory?

  name = source.basename.to_s
  destination = vendor.join(name)
  FileUtils.rm_rf(destination)
  # Copy what the gem needs, not its history or its build output.
  FileUtils.mkdir_p(destination)
  Dir.children(source).each do |entry|
    next if %w[.git tmp log node_modules test spec].include?(entry)
    FileUtils.cp_r(source.join(entry), destination)
  end

  relative = "vendor/path-gems/#{name}"
  lock = lock.gsub(/^(PATH\n  remote: )#{Regexp.escape(remote)}$/) { "#{$1}#{relative}" }

  gemfile_text = gemfile.read
  # Match any quoting and any `path:` / `:path =>` spelling of this remote.
  rewritten = gemfile_text.gsub(/(path:\s*|:path\s*=>\s*)(["'])#{Regexp.escape(remote)}\2/) do
    "#{$1}#{$2}#{relative}#{$2}"
  end
  if rewritten == gemfile_text
    abort "  #{remote} is in Gemfile.lock but not found as a path: in Gemfile; not guessing"
  end
  gemfile.write(rewritten)

  puts "  vendored #{name} from #{remote}"
end

lockfile.write(lock)

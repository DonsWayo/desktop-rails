# frozen_string_literal: true

# Downloads a published release's runtime and shell for this machine with the
# gem's own code — the same calls desktop:runtime and desktop:shell make — and
# proves the interpreter works from where it landed.
#
# Needs only the standard library, like the download code itself, so any Ruby
# can run it without a bundle:
#
#   ruby .github/scripts/prebuilt_check.rb [scratch dir]
#
# DESKTOP_RAILS_RELEASE_VERSION and DESKTOP_RAILS_RELEASE_URL are honoured, as
# they are by the tasks.

$LOAD_PATH.unshift(File.expand_path("../../desktop-rails/lib", __dir__))
require "desktop_rails/packaging"
require "desktop_rails/prebuilt"
require "fileutils"
require "tmpdir"

packaging = DesktopRails::Packaging

triple = packaging.release_triple || abort("No release is published for #{RbConfig::CONFIG["host_cpu"]}-#{RbConfig::CONFIG["host_os"]}.")
version = packaging.release_version
base_url = packaging.release_base_url

# A space in the path, because "Application Support" is on every Mac and a
# download that only works from a tidy path is not one.
scratch = ARGV[0] || File.join(Dir.mktmpdir("prebuilt-check"), "with space")
FileUtils.mkdir_p(scratch)
runtime = File.join(scratch, "runtime")
shell = File.join(scratch, "shell", version, packaging.shell_executable_name)

puts "desktop-rails #{version}, #{triple}, from #{base_url}"
DesktopRails::Prebuilt.install_runtime(into: runtime, triple: triple, version: version, base_url: base_url)
DesktopRails::Prebuilt.install_shell(into: shell, triple: triple, version: version, base_url: base_url)

ruby = File.join(runtime, "bin", Gem.win_platform? ? "ruby.exe" : "ruby")
# Nothing from the Ruby running this script may leak into the one under test.
clean = { "RUBYOPT" => nil, "RUBYLIB" => nil, "GEM_HOME" => nil, "GEM_PATH" => nil, "BUNDLE_GEMFILE" => nil }
print "extracted ruby: "
$stdout.flush
system(clean, ruby, "-ropenssl", "-ryaml", "-e", "puts OpenSSL::OPENSSL_LIBRARY_VERSION") ||
  abort("the downloaded interpreter did not run")
system(clean, ruby, "-e", "puts RUBY_DESCRIPTION") || abort("the downloaded interpreter did not run")
system(clean, *packaging.runtime_check_command(runtime)) ||
  abort("the downloaded interpreter failed the runtime check")

abort "the shell is not executable: #{shell}" unless File.file?(shell) && File.executable?(shell)
magic = File.binread(shell, 4).unpack1("H*")
puts "shell: #{shell} (#{File.size(shell)} bytes, magic #{magic})"
system("file", shell) unless Gem.win_platform?
puts "OK"

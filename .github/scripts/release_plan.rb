# frozen_string_literal: true

# Works out what a release is called and what it must carry, from the gem.
#
# The gem computes every download URL from DesktopRails::VERSION, so the
# release has to be named from it too, and by the same code. This asks
# DesktopRails::Packaging rather than repeating its naming scheme in YAML, and
# refuses to go on when the tag, Cargo.toml, package.json or tauri.conf.json
# disagree with the gem — a release no installed gem can find is worse than no
# release.
#
# Runs with any Ruby: packaging.rb needs only the standard library.
#
# Usage: ruby .github/scripts/release_plan.rb   (writes to $GITHUB_OUTPUT)

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "desktop-rails", "lib"))
require "json"
require "desktop_rails/version"
require "desktop_rails/packaging"

packaging = DesktopRails::Packaging
version = DesktopRails::VERSION
tag = packaging.release_tag(version)

if ENV["GITHUB_EVENT_NAME"] == "push" && ENV["GITHUB_REF_NAME"] != tag
  abort "Tag #{ENV["GITHUB_REF_NAME"]} does not match the gem: desktop-rails #{version} " \
        "downloads from #{tag}. Bump DesktopRails::VERSION or push #{tag}."
end

semver = packaging.semver(version)
declared = {
  "src-tauri/Cargo.toml" => File.read(File.join(root, "src-tauri", "Cargo.toml"))[/^version\s*=\s*"([^"]+)"/, 1],
  "src-tauri/tauri.conf.json" => JSON.parse(File.read(File.join(root, "src-tauri", "tauri.conf.json")))["version"],
  "package.json" => JSON.parse(File.read(File.join(root, "package.json")))["version"]
}
wrong = declared.reject { |_, found| found == semver }
unless wrong.empty?
  abort wrong.map { |file, found| "#{file} says #{found}; desktop-rails #{version} needs #{semver}." }.join("\n")
end

assets = packaging::RELEASE_TRIPLES.to_h do |triple|
  [ triple, { "runtime" => packaging.runtime_asset_name(version: version, triple: triple),
              "shell" => packaging.shell_asset_name(version: version, triple: triple) } ]
end

outputs = {
  "version" => version,
  "tag" => tag,
  "prerelease" => packaging.prerelease?(version).to_s,
  "assets" => JSON.generate(assets),
  "expected" => packaging.release_asset_names(version: version).join(" ")
}
outputs.each { |key, value| puts "#{key}=#{value}" }
File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |out| outputs.each { |key, value| out.puts "#{key}=#{value}" } } if ENV["GITHUB_OUTPUT"]

# frozen_string_literal: true

# Which release this run's fresh app should download from.
#
# `desktop:runtime` and `desktop:shell` download the release named after the
# gem's own version, which is right for a user: they install a released gem.
# In this repository the version is bumped in the commit that is then tagged,
# so between the bump and the release workflow finishing there is a window in
# which the gem asks for a release nobody has published yet. Every release so
# far (pre2, pre3, pre4) failed this workflow that way, on every platform.
#
# So: use the gem's release when it exists, and otherwise the newest published
# one, saying which. The journey is still followed with a real release; only
# the version differs, and the run says so rather than failing on a race.
#
# Writes DESKTOP_RAILS_RELEASE_VERSION to $GITHUB_ENV, or nothing at all when
# the gem's own release is there.

require "json"
require "net/http"
require "uri"

ROOT = File.expand_path("../..", __dir__)
API = ENV.fetch("GITHUB_API_URL", "https://api.github.com")
REPO = ENV.fetch("GITHUB_REPOSITORY")

def gem_version
  File.read(File.join(ROOT, "desktop-rails", "lib", "desktop_rails", "version.rb"))[/VERSION\s*=\s*"([^"]+)"/, 1] ||
    abort("Could not read the gem version.")
end

def api(path)
  uri = URI.join("#{API}/", path)
  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "application/vnd.github+json"
  request["User-Agent"] = "desktop-rails-ci"
  token = ENV["GITHUB_TOKEN"]
  request["Authorization"] = "Bearer #{token}" if token && !token.empty?
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  abort("#{uri} answered #{response.code} #{response.message}") unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
end

# A release is usable once its assets are up: the checksums are uploaded with
# them, so their absence is what "not published yet" looks like from here.
def published?(release)
  release["assets"].any? { |asset| asset["name"] == "SHA256SUMS" }
end

version = gem_version
releases = api("repos/#{REPO}/releases?per_page=30")
wanted = releases.find { |release| release["tag_name"] == "v#{version}" }

if wanted && published?(wanted)
  puts "Release v#{version} is published; the fresh app downloads its own version."
  exit
end

fallback = releases.find { |release| published?(release) } ||
           abort("No published release carries SHA256SUMS, so there is nothing to download.")
tag = fallback["tag_name"]
puts "::notice::v#{version} is not published yet; downloading #{tag} instead."

File.open(ENV.fetch("GITHUB_ENV"), "a") do |env|
  env.puts("DESKTOP_RAILS_RELEASE_VERSION=#{tag.delete_prefix("v")}")
end

require_relative "lib/desktop_rails/version"

Gem::Specification.new do |spec|
  spec.name          = "desktop-rails"
  spec.version       = DesktopRails::VERSION
  spec.authors       = [ "Juan Carracedo", "aguspe" ]

  spec.summary       = "Ship your Rails app as a desktop app"
  spec.description   = "Packages a Rails app with its own Ruby into a native desktop shell: Hotwire in a webview, Turbo Streams over SSE, native calls from Ruby and JavaScript, and installers for macOS, Linux and Windows."
  spec.homepage      = "https://github.com/DonsWayo/desktop-rails"
  spec.license       = "MIT"

  # Rails 8's own floor.
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"]      = spec.homepage
  spec.metadata["source_code_uri"]   = spec.homepage
  spec.metadata["changelog_uri"]     = "#{spec.homepage}/blob/main/desktop-rails/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "app/**/*", "config/**/*", "LICENSE", "README.md", "CHANGELOG.md"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 7.0"
  spec.add_dependency "turbo-rails", ">= 1.0"
end

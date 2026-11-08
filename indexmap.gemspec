# frozen_string_literal: true

require_relative "lib/indexmap/version"

Gem::Specification.new do |spec|
  spec.name = "indexmap"
  spec.version = Indexmap::VERSION
  spec.authors = ["Paulo Fidalgo", "Ethos Link"]
  spec.email = ["devel@ethos-link.com"]

  spec.summary = "Generate sitemap indexes and child sitemaps with plain Ruby"
  spec.description = "A small Ruby gem for generating sitemap indexes and child sitemaps from explicit section definitions, with optional Rails rake task integration."
  spec.homepage = "https://www.ethos-link.com/opensource/indexmap"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0"

  repo = "https://github.com/ethos-link/indexmap"
  reference = "v#{spec.version}"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => repo,
    "bug_tracker_uri" => "#{repo}/issues",
    "changelog_uri" => "#{repo}/blob/#{reference}/CHANGELOG.md",
    "documentation_uri" => spec.homepage,
    "funding_uri" => "https://www.reviato.com/",
    "github_repo" => "ssh://github.com/ethos-link/indexmap",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(__dir__) do
    (Dir["lib/**/*", "test/**/*", "docs/**/*"] + ["CHANGELOG.md", "LICENSE.txt", "README.md", "UPGRADE.md"]).select { |file| File.file?(file) }.uniq.sort
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 8.0", "< 9"
  spec.add_dependency "faraday", ">= 2.0"
  spec.add_dependency "google-apis-searchconsole_v1", ">= 0.18"
  spec.add_dependency "googleauth", ">= 1.12"
  spec.add_dependency "nokogiri", ">= 1.16"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "webmock", "~> 3.0"
end

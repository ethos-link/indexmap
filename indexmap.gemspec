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
  spec.required_ruby_version = ">= 3.2.0"

  repo = "https://github.com/ethos-link/indexmap"
  branch = "main"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => repo,
    "bug_tracker_uri" => "#{repo}/issues",
    "changelog_uri" => "#{repo}/blob/#{branch}/CHANGELOG.md",
    "documentation_uri" => "#{repo}/blob/#{branch}/README.md",
    "funding_uri" => "https://www.reviato.com/",
    "github_repo" => "ssh://github.com/ethos-link/indexmap",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    allowed_prefixes = %w[lib/ test/].freeze
    allowed_files = %w[CHANGELOG.md LICENSE.txt README.md].freeze
    git_files = `git ls-files -z 2>/dev/null`.split("\x0")
    candidate_files = git_files.empty? ? Dir.glob("{lib,test}/**/*", File::FNM_DOTMATCH) + allowed_files : git_files

    candidate_files.select do |file|
      next false if File.directory?(file)

      allowed_files.include?(file) || allowed_prefixes.any? { |prefix| file.start_with?(prefix) }
    end.uniq
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 7.1"
  spec.add_dependency "nokogiri", ">= 1.16"
  spec.add_dependency "railties", ">= 7.1"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "standard", "~> 1.0"
end

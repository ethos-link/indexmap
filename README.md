# Indexmap

[![Gem Version](https://badge.fury.io/rb/indexmap.svg)](https://badge.fury.io/rb/indexmap)
[![Ruby](https://github.com/ethos-link/indexmap/actions/workflows/ruby.yml/badge.svg)](https://github.com/ethos-link/indexmap/actions/workflows/ruby.yml)

`indexmap` is a small Ruby gem for generating XML sitemaps from explicit Ruby data.

It is designed for Rails apps that want:

- deterministic sitemap output
- plain Ruby configuration
- first-party rake tasks instead of a large DSL
- easy extraction of sitemap logic into app-owned manifests

By default, `indexmap` writes a sitemap index plus one or more child sitemap files. For simpler sites, it also supports `:single_file` mode, which writes a single `urlset` directly to `sitemap.xml`.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "indexmap"
```

And then execute:

```bash
bundle install
```

Or install it directly:

```bash
gem install indexmap
```

## Ruby Usage

```ruby
require "indexmap"

sections = [
  Indexmap::Section.new(
    filename: "sitemap-marketing.xml",
    entries: [
      Indexmap::Entry.new(loc: "https://example.com/"),
      Indexmap::Entry.new(loc: "https://example.com/pricing", lastmod: Date.new(2026, 4, 21))
    ]
  )
]

Indexmap::Writer.new(
  sections: sections,
  public_path: Pathname("public"),
  base_url: "https://example.com"
).write
```

## Rails Usage

In an initializer:

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.public_path = -> { Rails.public_path }
  config.sections = -> do
    [
      Indexmap::Section.new(
        filename: "sitemap-marketing.xml",
        entries: [
          Indexmap::Entry.new(loc: "https://example.com/")
        ]
      )
    ]
  end
end
```

Then run:

```bash
bin/rails indexmap:sitemap:create
bin/rails indexmap:sitemap:format
bin/rails indexmap:sitemap:validate
```

`indexmap:sitemap:create` is the main task. It writes sitemap files to a local
temporary directory, formats them, validates the result, then replaces the final
XML files. Existing sitemap files are left untouched if generation or validation
fails.

### Default Index Mode

This is the default behavior. `indexmap` writes:

- `public/sitemap.xml` as a sitemap index
- one or more child sitemap files from `config.sections`

### Single-File Mode

For sites that only want one `public/sitemap.xml` file:

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.public_path = -> { Rails.public_path }
  config.format = :single_file
  config.entries = -> do
    [
      Indexmap::Entry.new(loc: "https://example.com/"),
      Indexmap::Entry.new(loc: "https://example.com/about", lastmod: Date.new(2026, 4, 21))
    ]
  end
end
```

In `:single_file` mode, `indexmap` writes a `urlset` directly to `sitemap.xml` and reads entries from `config.entries` instead of `config.sections`.

### Named Outputs

Most apps only need the default output. Use named outputs when one part of the
sitemap must be generated separately, for example when static pages can be
generated during deploy but database-heavy pages should refresh later. Named
outputs still write normal sitemap XML files to a filesystem path; storage and
serving are application concerns.

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.public_path = -> { Rails.root.join("storage/sitemaps") }
  config.sections = -> { Sitemap.sections }

  config.output :insights_data do |output|
    output.format = :single_file
    output.index_filename = "sitemap-insights-data.xml"
    output.entries = -> { Sitemap.insights_data_entries }
  end
end
```

Generate the default output:

```ruby
Indexmap.create
```

Generate only the named output:

```ruby
Indexmap.create(:insights_data)
```

Named outputs inherit `base_url`, `public_path`, and `format` from the main
configuration unless you override them.

`Indexmap.create` uses the same safe local publish flow as the rake task:
generate in a temporary directory, format, validate, and then replace the final
XML file or files.

### Deferred Dynamic Sections

Use `after_create` when `indexmap:sitemap:create` should publish the default
sitemap first, then schedule slower dynamic sections for the background. The
callback runs only after the generated files have been formatted, validated, and
replaced successfully.

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.public_path = -> { Rails.root.join("storage/sitemaps") }
  config.sections = -> { Sitemap.sections }

  config.output :insights_data do |output|
    output.format = :single_file
    output.index_filename = "sitemap-insights-data.xml"
    output.entries = -> { Sitemap.insights_data_entries }
  end

  config.after_create do
    Insights::SitemapRefreshJob.perform_later
  end
end
```

Then the job can stay small:

```ruby
class Insights::SitemapRefreshJob < ApplicationJob
  def perform
    Indexmap.create(:insights_data)
  end
end
```

This keeps deploys fast: the deploy only waits for `indexmap:sitemap:create`,
while database-dependent output is refreshed by the job backend.

## Validation And Parsing

`indexmap` also includes small utilities for working with generated sitemap files:

```ruby
parser = Indexmap::Parser.new(path: Rails.public_path.join("sitemap.xml"))
parser.paths
# => ["/", "/about", "/articles/example"]

Indexmap::Validator.new.validate!
```

The built-in validator checks for:

- missing sitemap files
- malformed sitemap XML
- empty sitemap files
- missing or duplicate child sitemap references
- duplicate sitemap URLs
- parameterized URLs in sitemap entries
- fragment URLs in sitemap entries
- non-HTTP or relative URLs
- URLs outside the configured `base_url`
- invalid `lastmod` values

## Search Engine Ping

`indexmap` can ping Google Search Console and IndexNow after sitemap generation.

Available rake tasks:

```bash
bin/rails indexmap:sitemap:validate
bin/rails indexmap:google:ping
bin/rails indexmap:index_now:ping
bin/rails indexmap:index_now:write_key
bin/rails indexmap:ping
```

### Google Search Console

Google pinging requires service account credentials:

```ruby
Indexmap.configure do |config|
  config.google.credentials = -> { ENV["GOOGLE_SITEMAP"] }
end
```

If `config.google.credentials` is blank, `indexmap:google:ping` skips Google submission.

You can optionally override the Search Console property identifier:

```ruby
Indexmap.configure do |config|
  config.google.credentials = -> { ENV["GOOGLE_SITEMAP"] }
  config.google.property = -> { "sc-domain:example.com" }
end
```

If `config.google.property` is not set, `indexmap` defaults to `sc-domain:<host>`.

### IndexNow

IndexNow submission requires a key. `indexmap` supports two ways to provide it:

- set `config.index_now.key`
- or keep a valid verification file at `public/<key>.txt`

Configured-key example:

```ruby
Indexmap.configure do |config|
  config.index_now.key = -> { ENV["INDEXNOW_KEY"] }
end
```

If `config.index_now.key` is set, `indexmap:sitemap:create` also ensures the matching `public/<key>.txt` verification file exists. It leaves an existing valid key file unchanged.

If your sitemap XML is generated in a staging directory but the IndexNow key is served from a different public path, configure the key path explicitly:

```ruby
Indexmap.configure do |config|
  config.index_now.key = -> { ENV["INDEXNOW_KEY"] }
  config.index_now.key_path = -> { Rails.public_path.join("#{ENV.fetch("INDEXNOW_KEY")}.txt") }
end
```

You can also disable automatic key-file writes entirely:

```ruby
Indexmap.configure do |config|
  config.index_now.key = -> { ENV["INDEXNOW_KEY"] }
  config.index_now.write_key_file = false
end
```

If you prefer the file-based flow, run:

```bash
bin/rails indexmap:index_now:write_key
```

That task:

- reuses an existing valid key file when present
- otherwise generates a new key in `public/<key>.txt`
- makes that key available to `indexmap:index_now:ping` without adding `config.index_now.key`

If neither a configured key nor a valid key file is present, `indexmap:index_now:ping` skips IndexNow submission.

## Development

Run tests:

```bash
bundle exec rake test
```

Run lint:

```bash
bundle exec rake standard
```

Run the full default task:

```bash
bundle exec rake
```

Tests generate a coverage report automatically.

Note: `Gemfile.lock` is intentionally not tracked for this gem, following normal Ruby library conventions.

### Git hooks

We use [lefthook](https://lefthook.dev/) with the Ruby [commitlint](https://github.com/arandilopez/commitlint) gem to enforce Conventional Commits on every commit. We also use [Standard Ruby](https://standardrb.com/) to keep code style consistent. CI validates commit messages, Standard Ruby, tests, and git-cliff changelog generation on pull requests and pushes to main/master.

Run the hook installer once per clone:

```bash
bundle exec lefthook install
```

## Release

Releases are tag-driven and published by GitHub Actions to RubyGems. Local release commands never publish directly.

Install [git-cliff](https://git-cliff.org/) locally before preparing a release. The release task regenerates `CHANGELOG.md` from Conventional Commits.

Before preparing a release, make sure you are on `main` or `master` with a clean worktree.

Then run one of:

```bash
bundle exec rake 'release:prepare[patch]'
bundle exec rake 'release:prepare[minor]'
bundle exec rake 'release:prepare[major]'
bundle exec rake 'release:prepare[0.1.0]'
```

The task will:

1. Regenerate `CHANGELOG.md` with `git-cliff`.
1. Update `lib/indexmap/version.rb`.
1. Commit the release changes.
1. Create and push the `vX.Y.Z` tag.

The `Release` workflow then runs tests, publishes the gem to RubyGems, and creates the GitHub release from the changelog entry.

## License

MIT License, see [LICENSE.txt](LICENSE.txt)

## About

Made by the team at [Ethos Link](https://www.ethos-link.com) — practical software for growing businesses. We build tools for hospitality operators who need clear workflows, fast onboarding, and real human support.

We also build [Reviato](https://www.reviato.com), “Capture. Interpret. Act.”.
Turn guest feedback into clear next steps for your team. Collect private appraisals, spot patterns across reviews, and act before small issues turn into public ones.

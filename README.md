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
bin/rails sitemap:create
bin/rails sitemap:format
bin/rails sitemap:validate
```

`sitemap:create` is the main task. It writes sitemap files, formats them, and validates the result.

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
- duplicate sitemap URLs
- parameterized URLs in sitemap entries

## Search Engine Ping

`indexmap` can ping Google Search Console and IndexNow after sitemap generation.

Available rake tasks:

```bash
bin/rails sitemap:validate
bin/rails sitemap:google:ping
bin/rails sitemap:index_now:ping
bin/rails sitemap:index_now:write_key
bin/rails sitemap:ping
```

### Google Search Console

Google pinging requires service account credentials:

```ruby
Indexmap.configure do |config|
  config.google.credentials = -> { ENV["GOOGLE_SITEMAP"] }
end
```

If `config.google.credentials` is blank, `sitemap:google:ping` skips Google submission.

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

If `config.index_now.key` is set, `sitemap:create` also writes the matching `public/<key>.txt` verification file automatically.

If you prefer the file-based flow, run:

```bash
bin/rails sitemap:index_now:write_key
```

That task:

- reuses an existing valid key file when present
- otherwise generates a new key in `public/<key>.txt`
- makes that key available to `sitemap:index_now:ping` without adding `config.index_now.key`

If neither a configured key nor a valid key file is present, `sitemap:index_now:ping` skips IndexNow submission.

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

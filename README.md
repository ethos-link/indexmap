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
gem "indexmap", require: false
```

`require: false` keeps sitemap generation and search-engine clients out of web
process boot. Require `indexmap` at the application boundary that generates a
sitemap, or use the task setup below.

And then execute:

```bash
bundle install
```

Or install it directly:

```bash
gem install indexmap
```

Upgrading an existing app? Read [UPGRADE.md](UPGRADE.md) before deploying,
especially if the app uses custom storage or stores sitemap files under a
directory prefix such as `sitemaps/`.

## Documentation

- [Search engine ping](docs/search-engine-ping.md): Google Search Console
  credentials, Google property configuration, and IndexNow key setup.
- [UPGRADE.md](UPGRADE.md): host-app migration steps for public contract
  changes.

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
  base_url: "https://example.com"
).write
```

## Rails Usage

Run the install generator after adding the gem:

```bash
bin/rails generate indexmap:install
```

The generator creates `config/initializers/indexmap.rb` with an idempotent
`IndexmapConfiguration.apply` loader and adds conditional `indexmap/tasks`
loading to the application's `Rakefile`. This preserves `bin/rails --tasks` and
the `indexmap:*` tasks without loading Indexmap during normal Rails boot.

Customize the `Indexmap.configure` block inside the generated initializer:

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = -> do
    Indexmap::Storage::Filesystem.new(
      path: Rails.public_path,
      public_url: config.base_url
    )
  end
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

Runtime callers and jobs must apply the generated configuration before using
Indexmap:

```ruby
IndexmapConfiguration.apply
Indexmap.create
```

Rake tasks apply it automatically because `indexmap/tasks` loads the gem before
Rails evaluates the initializer.

Then run:

```bash
bin/rails indexmap:sitemap:create
bin/rails indexmap:sitemap:format
bin/rails indexmap:sitemap:validate
```

`indexmap:sitemap:create` is the main task. It builds sitemap files in memory,
formats them, validates the result, then writes the final XML files to the
configured storage. Existing sitemap files are left untouched if generation or
validation fails.

### Background Generation

Keep the refresh job and its scheduling in the host application. Indexmap does
not select a queue adapter, run workers, or deduplicate jobs. Apply the generated
configuration inside the job. Use `Indexmap::TaskRunner.new.create` for the
rake task's complete lifecycle, including `after_create` callbacks and IndexNow
key-file handling; `Indexmap.create` only generates the selected output.

#### GoodJob

With GoodJob 4.22.1 or newer, use its public labelled concurrency rules:

```ruby
class SitemapRefreshJob < ApplicationJob
  include GoodJob::ActiveJobExtensions::Concurrency

  good_job_concurrency_rule(
    perform_limit: 1,
    label: "sitemap-refresh",
    apply_label: true
  )

  good_job_concurrency_rule(
    total_limit: 1,
    label: -> { "sitemap-refresh:#{arguments.first}" },
    apply_label: true
  )

  def perform(_version)
    IndexmapConfiguration.apply
    Indexmap::TaskRunner.new.create
  end
end
```

Enqueue with a release identifier: `SitemapRefreshJob.perform_later(version)`.
The version label limits unfinished work for that release; the shared label
limits generation across releases to one execution at a time. A newer release
can enqueue while an older refresh is unfinished. A repeat enqueue is allowed
after completion: these controls do not provide permanent once-per-release
tracking. Use `perform_later`; direct `perform_now` calls bypass GoodJob's limits.
See [GoodJob concurrency controls](https://github.com/bensheldon/good_job#concurrency-controls).

#### Solid Queue

With Solid Queue 1.7 or newer, serialize writes to the shared sitemap output:

```ruby
class SitemapRefreshJob < ApplicationJob
  limits_concurrency to: 1, key: "sitemap-refresh",
    duration: 30.minutes, on_conflict: :block

  def perform(_version)
    IndexmapConfiguration.apply
    Indexmap::TaskRunner.new.create
  end
end
```

Choose a duration longer than the expected generation time. `:block` retains
every refresh and runs them serially; it does not suppress duplicate enqueues.
Using `on_conflict: :discard` coalesces conflicting requests, including requests
for newer releases when the key is shared. A version-based key such as
`->(version) { "sitemap-refresh:#{version}" }` scopes conflicts to that release,
but permits different releases to write concurrently. Select that tradeoff
explicitly; it is not equivalent to GoodJob's two rules above. Direct
`perform_now` calls bypass queue coordination.
See [Solid Queue concurrency controls](https://github.com/rails/solid_queue#concurrency-controls).

#### Triggering Refreshes

Enqueue from one release task, a recurring schedule, or application startup.
Rails' `after_initialize` hook can enqueue from a worker application without
depending on a backend's worker callbacks:

```ruby
Rails.application.config.after_initialize do
  if Rails.env.production? && ENV["PROCESS_ROLE"] == "worker"
    SitemapRefreshJob.perform_later(ENV.fetch("RELEASE_VERSION")) do |job|
      raise job.enqueue_error if job.enqueue_error
    end
  end
end
```

`PROCESS_ROLE` and `RELEASE_VERSION` are application-defined environment values.
Configure them in the deployment, with the worker role flag limited to worker
processes. `after_initialize` runs for every Rails process, including commands;
it indicates application initialization, not worker readiness. Complete database
preparation before starting workers. Suppressed enqueues are expected; report
actual enqueue errors. Avoid scheduling the same refresh from both startup and
a release task.

Use storage shared by all serving containers, such as object storage through
the Active Storage adapter. A job container's local filesystem is not shared
with web containers unless the deployment mounts the same persistent storage.

### Default Index Mode

This is the default behavior. `indexmap` writes:

- `sitemap.xml` as a sitemap index
- one or more child sitemap files from `config.sections`

### Single-File Mode

For sites that only want one `sitemap.xml` file:

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = -> { Indexmap::Storage::Filesystem.new(path: Rails.public_path, public_url: config.base_url) }
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
outputs write through the same configured storage as the default output.

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = -> { Indexmap::Storage::Filesystem.new(path: Rails.root.join("storage/sitemaps"), public_url: config.base_url) }
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

Named outputs inherit `base_url` and `format` from the main configuration unless
you override them. Storage is configured once and shared by every output.

`Indexmap.create` uses the same safe publish flow as the rake task: build,
format, validate, and then write the final XML file or files to storage.

### Storage

Every `indexmap` operation reads and writes through `config.storage`. The storage
object is the source of truth for generation, validation, parsing, Google
submission, IndexNow submission, and IndexNow verification files.

The filesystem adapter stores files in a directory and exposes public URLs from
the same filenames:

```ruby
Indexmap.configure do |config|
  config.base_url = "https://example.com"
  config.storage = Indexmap::Storage::Filesystem.new(
    path: Rails.public_path,
    public_url: "https://example.com"
  )
end
```

Rails apps that store sitemap files in Active Storage can use the optional
adapter. `indexmap` does not depend on `activestorage`; this adapter only uses
the model and attachment object you pass in.

```ruby
Indexmap.configure do |config|
  config.base_url = "https://example.com"
  config.storage = Indexmap::Storage::ActiveStorage.new(
    model: SitemapArtifact,
    filename_column: :filename,
    attachment: :file,
    public_url: "https://example.com"
  )
end
```

Custom storage backends can implement the same small interface:

```ruby
storage.write(filename, body, content_type:)
storage.read(filename)
storage.exist?(filename)
storage.list(prefix:, suffix:)
storage.delete(filename)
storage.public_url(filename)
```

### Deferred Dynamic Sections

Use `after_create` when `indexmap:sitemap:create` should publish the default
sitemap first, then schedule slower dynamic sections for the background. The
callback runs only after the generated files have been formatted, validated, and
replaced successfully.

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = -> { Indexmap::Storage::Filesystem.new(path: Rails.root.join("storage/sitemaps"), public_url: config.base_url) }
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
    IndexmapConfiguration.apply
    Indexmap.create(:insights_data)
  end
end
```

This keeps deploys fast: the deploy only waits for `indexmap:sitemap:create`,
while database-dependent output is refreshed by the job backend.

## Validation And Parsing

`indexmap` also includes small utilities for working with generated sitemap files:

```ruby
parser = Indexmap::Parser.new(source: "sitemap.xml")
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
See [Search engine ping](docs/search-engine-ping.md) for Google credential
setup, Search Console property configuration, and IndexNow key provisioning.

Available rake tasks:

```bash
bin/rails indexmap:sitemap:validate
bin/rails indexmap:google:ping
bin/rails indexmap:index_now:ping
bin/rails indexmap:index_now:write_key
bin/rails indexmap:ping
```

If Google credentials are blank, `indexmap:google:ping` skips Google
submission. If neither a configured IndexNow key nor a valid key file is
present, `indexmap:index_now:ping` skips IndexNow submission.

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

We use [lefthook](https://lefthook.dev/) with the Ruby
[commitlint](https://github.com/arandilopez/commitlint) gem to enforce
Conventional Commits on every commit. We also use
[Standard Ruby](https://standardrb.com/) to keep code style consistent. CI
validates commit messages, Standard Ruby, tests, and git-cliff changelog
generation on pull requests and pushes to main/master.

Run the hook installer once per clone:

```bash
bundle exec lefthook install
```

## Release

Releases are tag-driven and published by GitHub Actions to RubyGems.
Local release commands never publish directly.

Install [git-cliff](https://git-cliff.org/) locally before preparing a
release. The release task prepends the next `CHANGELOG.md` section from
Conventional Commits.

Before preparing a release, make sure you are on `main` or `master` with a
clean worktree. If the release contains a breaking public-contract change,
update `UPGRADE.md` with the host-app migration steps first.

Then run one of:

```bash
bundle exec rake 'release:prepare[patch]'
bundle exec rake 'release:prepare[minor]'
bundle exec rake 'release:prepare[major]'
bundle exec rake 'release:prepare[0.1.0]'
```

The task will:

1. Prepend the next `CHANGELOG.md` section with `git-cliff`.
1. Update `lib/indexmap/version.rb`.
1. Commit the release changes.
1. Create and push the `vX.Y.Z` tag.

The `Release` workflow then runs tests, publishes the gem to RubyGems,
and creates the GitHub release from the changelog entry.

## License

MIT License, see [LICENSE.txt](LICENSE.txt)

## About

Made by the team at [Ethos Link](https://www.ethos-link.com) — practical software for growing businesses. We build tools for hospitality operators who need clear workflows, fast onboarding, and real human support.

We also build [Reviato](https://www.reviato.com), “Capture. Interpret. Act.”.
Turn guest feedback into clear next steps for your team. Collect private appraisals, spot patterns across reviews, and act before small issues turn into public ones.

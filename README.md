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

## Release status

This branch documents **unreleased main**, including partitioned generation,
atomic publication, sitemap and robots controllers, and IndexNow reports/retries.
The latest version recorded in this repository is **0.8.2**. For that release,
use the [0.8.2 README](https://github.com/ethos-link/indexmap/blob/v0.8.2/README.md)
and [changelog](CHANGELOG.md). Installing from RubyGems does not provide the
unreleased features below. Use a source checkout for evaluation until the next
release, and read [UPGRADE.md](UPGRADE.md) before adopting it.

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

- [How Indexmap works](docs/architecture.md): pipeline diagram and entrypoints.
- [Domain terms](docs/domain-terms.md): sections, partitions, outputs, publications,
  roots, and entry types.
- [Deployment guide](docs/deployment.md): development and production, static and
  database-backed sources, static files or Rails delivery, and robots.txt.
- [Storage contract](docs/storage.md): legacy, streaming, atomic, and pruning APIs.
- [Dynamic sitemaps](docs/dynamic-sitemaps.md): streaming and partitions, atomic
  publication, Rails delivery, retention, jobs, and host adoption.
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

Indexmap.configure do |config|
  config.base_url = "https://example.com"
  config.storage = Indexmap::Storage::Filesystem.new(
    path: "public", public_url: config.base_url
  )
  config.sections = sections
end

Indexmap.create
```

## Rails Usage

Run the install generator after adding the gem:

```bash
bin/rails generate indexmap:install
```

The generator creates `config/initializers/indexmap.rb` with an idempotent
`Indexmap::HostConfiguration.apply` loader and adds conditional `indexmap/tasks`
loading to the application's `Rakefile`. This preserves `bin/rails --tasks` and
the `indexmap:*` tasks without loading Indexmap during normal Rails boot.

Customize the `Indexmap.configure` block inside the generated initializer:

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = Indexmap::Storage::Filesystem.new(
    path: Rails.public_path,
    public_url: config.base_url
  )
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
Indexmap::HostConfiguration.apply
Indexmap.create
```

Rake tasks apply it automatically because `indexmap/tasks` loads the gem before
Rails evaluates the initializer.

Then run:

```bash
bin/rails indexmap:sitemap:create
bin/rails indexmap:sitemap:validate
```

Creation already validates. `indexmap:sitemap:format` optionally pretty-prints
legacy XML after publication; it rejects atomic outputs.

`indexmap:sitemap:create` is the main task. It stages partitioned XML on temporary
disk, validates the complete result, then publishes to configured storage.
Generation and validation failures leave published files untouched. Legacy
publication remains sequential; enable atomic mode for immutable children and
revision-checked root activation. See [dynamic sitemaps](docs/dynamic-sitemaps.md).

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
    Indexmap::HostConfiguration.apply
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
    Indexmap::HostConfiguration.apply
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

#### Operating Practices And Current Limits

Generate database-backed content after database preparation, through one
host-owned refresh job. Load the existing configuration inside that job and
query eligible records when it runs. Pass release or output identifiers rather
than relations, URL inventories, or credentials. Keep queue selection, recurring
schedules, and any application authorization context in the host.

Use a shared concurrency key or label for jobs writing the same destination,
across releases. Prefer blocking or rescheduling conflicts to discarding a newer
refresh. Backend controls do not protect manual rake invocations, and Solid
Queue's concurrency duration can expire before an unusually long job finishes.
Avoid concurrent writers through all entrypoints in legacy mode: an interrupted
sequential publication can leave mixed generations. Opt-in atomic mode checks
root revisions under a storage lock and retains previous generations. See the
[publication and retention contract](docs/dynamic-sitemaps.md#atomic-publication-and-storage).

Keep generation and search-engine submission separate. A refresh retry should
not automatically resend successful IndexNow batches. Make `after_create`
callbacks safe to repeat: they run after publication, and a callback failure does
not roll published files back. Validate the deployed sitemap and preview IndexNow
selection before submitting. See [selection and attempt reports](docs/search-engine-ping.md#inspect-selection-and-actual-attempts).

Batch source queries with native Rails APIs and select the fields needed for
URLs and dates. Supply meaningful content dates; do not use the refresh time as
`lastmod`. Each sitemap must stay within 50,000 entries and 52,428,800 uncompressed
bytes. Index mode partitions automatically; single-file mode rejects an output
that needs splitting. Measure the complete refresh before adding parallel jobs or
caches. Supply lazy sources to benefit from incremental generation and validation;
app-owned arrays and explicit inventory-returning APIs still retain their data.

Generation uses the same synchronous entrypoints with GoodJob and Solid Queue;
the examples above describe their different concurrency behavior. Verify the
host's actual adapter, workers, shared storage, failure reporting, and intended
system context in integration tests. Gem tests alone do not establish those
deployment guarantees.

### Dynamic Robots

Indexmap can serve `/robots.txt` from configuration without querying content or
reading sitemap storage. Crawling defaults to disabled. Inside the generated
`Indexmap.configure` block, configure the site's policy:

```ruby
config.robots.indexable = -> { Rails.env.production? && ENV["PUBLIC_INDEXING"] == "1" }
config.robots.groups = [
  {user_agent: "*", allow: ["/"], disallow: ["/admin/", "/search"]}
]
```

The sitemap URL defaults to `base_url` plus `index_filename`. Override it with
`config.robots.sitemaps = ["https://example.com/sitemap.xml"]` when needed.
Groups and sitemap lists also accept callables. Keep them configuration-only;
do not query models in these callables.

In the application's `config/routes.rb`, load and mount the endpoint explicitly:

```ruby
require "indexmap/robots_controller"
Indexmap::HostConfiguration.apply

Rails.application.routes.draw do
  get "/robots.txt", to: Indexmap::RobotsController.action(:show)
end
```

If the configuration loader lives outside an initializer, require that file
before applying it. Remove `public/robots.txt` so it cannot shadow the route.
The controller supports GET, HEAD, and conditional requests, uses a one-hour
public cache, and does not inherit application authentication or browser gates.
Set `PUBLIC_INDEXING` only for the intended public deployment; production-mode
previews should remain disabled. Robots rules do not replace authorization or
page-level indexing directives.

### Default Index Mode

This is the default behavior. `indexmap` writes:

- `sitemap.xml` as a sitemap index
- one or more child sitemap files from `config.sections`

Section entries can be enumerables. Indexmap consumes each section once and
calculates its index `lastmod` in that same pass. For database sources, return a
fresh enumerable from the configured sections callable on every generation:

```ruby
config.sections = -> do
  entries = PublicPage.indexable.find_each.lazy.map do |page|
    Indexmap::Entry.new(loc: page.canonical_url, lastmod: page.updated_at)
  end
  [Indexmap::Section.new(filename: "sitemap-pages.xml", entries: entries)]
end
```

`PublicPage`, its eligibility scope, and canonical URL method are host-app
examples. Keep queries and routing decisions in the host. Generation stages
bounded partitions and validates incrementally, using temporary disk for global
duplicate checks. See [memory and disk limits](docs/dynamic-sitemaps.md#configure-generation).

### Single-File Mode

For sites that only want one `sitemap.xml` file:

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = Indexmap::Storage::Filesystem.new(path: Rails.public_path, public_url: config.base_url)
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
  config.storage = Indexmap::Storage::Filesystem.new(path: Rails.root.join("storage/sitemaps"), public_url: config.base_url)
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

`Indexmap.create` stages XML, validates it, then publishes the selected output.
Only `Indexmap::TaskRunner#create` (also used by the create task) handles the
IndexNow key file and `after_create` callbacks. Formatting is a separate optional
operation for legacy outputs; atomic outputs must be regenerated.

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

Atomic publication, pruning, and streamed HTTP delivery require additional
capabilities. See the [storage contract](docs/storage.md) for signatures,
return values, and adapter requirements. Each operation instance resolves a
storage callable once and shares the adapter with its collaborators. Create a
fresh runner/pinger after changing destinations or tenant context. Direct reads
of `config.storage` still resolve the callable; construct an adapter once in the
host loader when its settings are fixed for the process.

### Deferred Dynamic Sections

Use `after_create` when `indexmap:sitemap:create` should publish the default
sitemap first, then schedule slower dynamic sections for the background. The
callback runs only after the default output has been validated and published
and configured IndexNow key-file handling has succeeded. It also runs for
`Indexmap::TaskRunner#create`; `Indexmap.create` does not run callbacks.

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = Indexmap::Storage::Filesystem.new(path: Rails.root.join("storage/sitemaps"), public_url: config.base_url)
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
    Indexmap::HostConfiguration.apply
    Indexmap.create(:insights_data)
  end
end
```

The default output and named output are independent roots. List both public
root URLs in `config.robots.sitemaps` (or the static robots file) and submit each
separately if needed; named outputs are not automatically linked into the default
index. Publish the named output before advertising its URL. A deferred job can
fail after the default root is published, so monitor it separately.

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

For Rails apps with sitemaps outside `public/`, see
[serving an IndexNow key from `public/`](docs/search-engine-ping.md#rails-public-key-file-with-separate-sitemap-storage).
Key discovery searches the configured sitemap storage, so an existing public
key file needs explicit configuration in that setup.

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

The gem requires Ruby 3.2+ and Active Support/railties 7.1+. CI exercises the
Rails 7.1 floor on Ruby 3.2 and Rails 8.1.4 integration on Ruby 4.0, alongside the
normal Ruby matrix. See [integration checks](docs/dynamic-sitemaps.md#integration-checks-from-a-source-checkout).

Install [git-cliff](https://git-cliff.org/) before running tests; the release
tests use it to generate changelogs in temporary repositories.

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

Before preparing a release, switch to updated `main` with a clean worktree
matching `origin/main`. If the release changes a public contract, merge the
`UPGRADE.md` migration steps before preparing the release.

Then run one of:

```bash
bundle exec rake 'release:prepare[patch]'
bundle exec rake 'release:prepare[minor]'
bundle exec rake 'release:prepare[major]'
bundle exec rake 'release:prepare[0.9.0]'
```

The task prepends the changelog and updates the version, preserving existing
history. It commits those two files on `main` with a Conventional Commit and
`What:`, `Why:`, and `Where:` in the body, pushes `main`, then creates and pushes
the annotated version tag. Review release-status notices before running it.
Hooks remain enabled; the branch
protection hook permits only the task's version and changelog commit on `main`.
Ordinary changes still require a topic branch. Remote branch protections must
permit the maintainer to push this release commit.

Preparation handles every local release step. The pushed tag triggers GitHub
Actions to publish the gem and create the GitHub release. Tagging requires clean
`main` matching `origin/main`, an unused version tag, and a matching changelog
section. Gem metadata links documentation to that version's tag.

If preparation stops after creating the release commit, resolve the failure and
push that existing commit to `main`. Resume tagging with:

```bash
bundle exec rake release:tag
```

This recovery command uses the already prepared version. Do not rerun preparation
with the same version. If the annotated tag already exists locally after a tag
push failure, retry `git push origin vX.Y.Z` with that version's tag.

The `Release` workflow then runs tests, publishes the gem to RubyGems,
and creates the GitHub release from the changelog entry.

## License

MIT License, see [LICENSE.txt](LICENSE.txt)

## About

Made by the team at [Ethos Link](https://www.ethos-link.com) — practical software for growing businesses. We build tools for hospitality operators who need clear workflows, fast onboarding, and real human support.

We also build [Reviato](https://www.reviato.com), “Capture. Interpret. Act.”.
Turn guest feedback into clear next steps for your team. Collect private appraisals, spot patterns across reviews, and act before small issues turn into public ones.

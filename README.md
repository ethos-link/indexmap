# Indexmap

[![Gem Version](https://badge.fury.io/rb/indexmap.svg)](https://badge.fury.io/rb/indexmap)
[![Commit messages](https://github.com/ethos-link/indexmap/actions/workflows/commitlint.yml/badge.svg)](https://github.com/ethos-link/indexmap/actions/workflows/commitlint.yml)

`indexmap` is a small Ruby gem for generating XML sitemaps from explicit Ruby data.

Use it from Ruby or an optional Rails 8 integration for:

- deterministic sitemap output
- plain Ruby configuration
- first-party rake tasks instead of a large DSL
- easy extraction of sitemap logic into app-owned manifests

By default, `indexmap` writes a sitemap index plus one or more child sitemap files. For simpler sites, it also supports `:single_file` mode, which writes a single `urlset` directly to `sitemap.xml`.

See [CHANGELOG.md](CHANGELOG.md) for published changes and [UPGRADE.md](UPGRADE.md)
for host migration steps.

## Requirements

Ruby 4.0 or newer. Active Support 8 is a runtime dependency; Rails itself is
optional. The Rails integration accepts Rails 8.0 or newer, below Rails 9.

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

This README and the linked repository guides describe the checked-out code.
The [Ethos Link project page](https://www.ethos-link.com/opensource/indexmap)
provides the canonical public project guide, overview and resources.

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

Run this from your project directory. It writes `public/sitemap.xml`, which
references `public/sitemap-marketing.xml`; the child contains the home and
pricing URLs. `Indexmap.create` generates and validates the selected output.
Use `Indexmap::TaskRunner#create` when you also need `after_create` callbacks
and IndexNow key-file handling.

## Rails Usage

Run the install generator after adding the gem:

```bash
bin/rails generate indexmap:install
```

The generator creates `config/initializers/indexmap.rb` using Rails' native
load hook and adds `require "indexmap/tasks"` to the application's `Rakefile`.
With the generated setup, normal web and worker boot does not load Indexmap.
Explicit runtime requires or mounted Indexmap controllers load it deliberately.
Rakefiles run only for tasks,
so task discovery needs no argument parsing.

Customize the generated initializer. `Sitemap.sections` below is an
application-owned method returning `Indexmap::Section` objects; replace it
with your own manifest or inline section definitions.

```ruby
ActiveSupport.on_load(:indexmap) do
  Indexmap.configure do |config|
    config.base_url = -> { ENV.fetch("BASE_URL", "https://example.com") }
    config.storage = -> do
      Indexmap::Storage::Filesystem.new(
        path: Rails.public_path, public_url: config.base_url
      )
    end
    config.sections = -> { Sitemap.sections }
  end
end
```

Keep storage, route helpers and source queries inside their callables. Passing
`public_url: config.base_url` while constructing an adapter outside a callable
resolves the origin immediately, before routes or later initializers may exist.
Moving that eager expression to `after_initialize` does not make route helpers
available reliably. The storage callable resolves once per operation.

Runtime callers only require the gem and invoke the operation:

```ruby
require "indexmap"
Indexmap::TaskRunner.new.create
```

The load hook applies configuration whether the gem loads before or after the
initializer. No host module, mutex, explicit apply call, or custom task loader
is needed. Existing manually configured Ruby callers remain supported.

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
not select a queue adapter, run workers, or deduplicate jobs. Require the gem
inside the job. Use `Indexmap::TaskRunner.new.create` for the
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
    require "indexmap"
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
    require "indexmap"
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

Rails.application.routes.draw do
  get "/robots.txt", to: Indexmap::RobotsController.action(:show)
end
```

Keep the load hook in an initializer. Remove `public/robots.txt` so it cannot
shadow the route.
The controller supports GET, HEAD, and conditional requests, uses a one-hour
public cache, and does not inherit application authentication or browser gates.
Set `PUBLIC_INDEXING` only for the intended public deployment; production-mode
previews should remain disabled. Robots rules do not replace authorization or
page-level indexing directives.

### Default Index Mode

This is the default behavior and the usual Google-aligned shape when a site has
more than one sitemap file. `indexmap` writes:

- `sitemap.xml` as a sitemap index
- one or more child sitemap files from `config.sections`

Put logical groups in sections (for example pages and jobs), keep the index at
the site root, and advertise or submit that single index URL in `robots.txt` /
Search Console. Child `lastmod` values come from each section's entries so
crawlers can refetch only the children that changed. Google requires a split
only after 50,000 URLs or 50 MB uncompressed per file; an index is still the
clearest discovery model when you split for structure before those limits.

Section entries can be enumerables. Indexmap consumes each section once and
calculates its index `lastmod` in that same pass. For database sources, return a
fresh enumerable from the configured sections callable on every generation:

```ruby
config.sections = -> do
  [
    Indexmap::Section.new(filename: "sitemap-pages.xml", entries: Sitemap.page_entries),
    Indexmap::Section.new(filename: "sitemap-jobs.xml", entries: Sitemap.job_entries)
  ]
end
```

`Sitemap.page_entries` / `Sitemap.job_entries`, eligibility scopes, and canonical
URL methods are host-app examples. Keep queries and routing decisions in the
host. Generation stages bounded partitions and validates incrementally, using
temporary disk for global duplicate checks. See
[memory and disk limits](docs/dynamic-sitemaps.md#configure-generation).

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

Most apps only need the default index. Prefer
[default index mode](#default-index-mode) when children should be discovered
through one `sitemap.xml`. Use named outputs only when a second public root must
be generated and submitted on its own timeline. Named outputs share storage with
the default output, but each named output is its own root. Indexmap does not add
a named output as a child of the default sitemap index. Keep those URLs out of
`config.sections`, and advertise every public root in `config.robots.sitemaps`
(or the static robots file) if you choose this model.

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = Indexmap::Storage::Filesystem.new(path: Rails.root.join("storage/sitemaps"), public_url: config.base_url)
  config.sections = -> { Sitemap.page_sections }

  config.output :insights_data do |output|
    output.format = :single_file
    output.index_filename = "sitemap-insights-data.xml"
    output.entries = -> { Sitemap.insights_data_entries }
  end

  config.robots.sitemaps = -> do
    [
      "#{config.base_url}/sitemap.xml",
      "#{config.base_url}/sitemap-insights-data.xml"
    ]
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
you override them. Storage is configured once and shared by every output. Empty
sections are omitted from an index; a single-file named output with an empty
`entries` array raises a configuration error, so skip creating that output when
it has nothing to publish.

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

### Deferred Named Outputs

Use `after_create` when `indexmap:sitemap:create` should publish the default
output first, then schedule a slower **named output** for the background. This
is not how to build Google's sitemap-index pattern: every section of the default
index still regenerates with that index. Prefer putting pages and jobs (or other
groups) in `config.sections` and refreshing the default output when any child
must change. Use deferred named outputs only when you intentionally want a
second root. The callback runs only after the default output has been validated
and published and configured IndexNow key-file handling has succeeded. It also
runs for `Indexmap::TaskRunner#create`; `Indexmap.create` does not run callbacks.

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = Indexmap::Storage::Filesystem.new(path: Rails.root.join("storage/sitemaps"), public_url: config.base_url)
  config.sections = -> { Sitemap.page_sections }

  config.output :insights_data do |output|
    output.format = :single_file
    output.index_filename = "sitemap-insights-data.xml"
    output.entries = -> { Sitemap.insights_data_entries }
  end

  config.robots.sitemaps = -> do
    [
      "#{config.base_url}/sitemap.xml",
      "#{config.base_url}/sitemap-insights-data.xml"
    ]
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
    require "indexmap"
    Indexmap.create(:insights_data)
  end
end
```

Publish the named output before crawlers are expected to fetch it. A deferred
job can fail after the default root is published, so monitor it separately.
Indexmap will not insert a named root into the default index; hosts that need
one index URL should keep those URLs in `config.sections` instead.

## Validation And Parsing

`indexmap` also includes small utilities for working with generated sitemap files:

```ruby
parser = Indexmap::Parser.new(source: "sitemap.xml")
parser.paths
# => ["/", "/pricing"]

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
For known page updates or removals, pass `entries:` directly to
`Indexmap::Pinger::IndexNow#ping`; see [direct change submission](docs/search-engine-ping.md#submit-known-changes-directly).
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

## License

MIT License, see [LICENSE.txt](LICENSE.txt)

## Development and releases

Shared tooling uses published [Ethos Gemkit](https://github.com/ethos-link/ethos-gemkit).
Keep the exact Gemfile version and workflow commit pins on the same release.

```sh
bundle install
bundle exec lefthook install
bundle exec rake verify
```

The PostgreSQL integration suite covers Active Storage, GoodJob and Solid Queue:

```sh
BUNDLE_GEMFILE=gemfiles/integration.gemfile bundle install
INDEXMAP_DATABASE_URL=postgresql://postgres@localhost:5432/indexmap_test \
  BUNDLE_GEMFILE=gemfiles/integration.gemfile bundle exec ruby script/integration
```

Use a disposable `indexmap_test` database; the integration suite recreates it.

Release preparation, publication, registry setup and recovery are documented
in the [Gemkit release guide](https://github.com/ethos-link/ethos-gemkit#releasing-a-gem).

## About Ethos Link

[Ethos Link](https://www.ethos-link.com) is a software company founded by
[Paulo Fidalgo](https://www.fidalgo.pt). This gem is part of the open-source
tooling we publish alongside our business products:

- [Reviato](https://www.reviato.com): collect private customer feedback and analyse public reviews.
- [Nuntio](https://www.nuntiohq.com): prepare, review and schedule social posts.
- [EthosPlaces](https://www.ethos.place): find places, opening hours and contact details.

Explore our [open-source projects](https://www.ethos-link.com/opensource).

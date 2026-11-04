# Database-backed sitemaps

Indexmap generates sitemap artifacts from app-owned sources. Generation can run
in a job or rake task; HTTP requests serve published artifacts and never query
source records. No model concern, queue backend, schedule, or content eligibility
policy is installed by the gem.

## Configure generation

Run `bin/rails generate indexmap:install`, then edit the generated configure block:

```ruby
config.base_url = -> { ENV.fetch("PUBLIC_ORIGIN") }
config.storage = -> do
  Indexmap::Storage::Filesystem.new(
    path: Rails.root.join("storage/sitemaps"), public_url: config.base_url
  )
end
config.atomic = true
config.max_urls = 45_000
config.sections = -> { Sitemap.sections }
```

`Sitemap` is the application's manifest. It should return fresh sections whose
entries are arrays or enumerables. Use native `find_each`/`in_batches`, selected
columns, and SQL aggregates to select eligible records. Calculate canonical URLs
with app-owned routing rules. Do not serialize a relation or URL inventory into
a job, reuse an exhausted source across refreshes, or use refresh time as the
content's `lastmod`. Time-dependent eligibility needs recurring refreshes even
when no record is updated. A batch scan is not a point-in-time database snapshot.

Generation stages XML on local temporary disk, validates the complete graph, then
publishes. Entry sources are consumed once. Index mode splits a section before
`max_urls` (default 50,000) or `max_bytes` (default 52,428,800) is exceeded. Limits
must be positive integers within the protocol limits. Size includes escaped UTF-8
XML and document overhead. Locations must be shorter than 2,048 characters.
A single oversized entry fails; a single-file output
that needs another partition fails with instructions to use index mode. Empty
sections are omitted; an empty root fails without replacing the published root.
The index itself must fit the protocol entry limit and configured byte limit.

In legacy mode, the first partition keeps the section filename; later partitions
append `-002.xml`, `-003.xml`, etc. Atomic mode chooses immutable child filenames
instead; the configured root filename remains stable. Do not infer eligibility,
content changes, or section identity from generated child filenames.

For filesystem and Active Storage destinations, generation and validation retain
at most a partition plus bounded parsing/sort buffers in memory, along with
metadata proportional to the number of sitemap files. Duplicate checking uses
10,000-URL sorted runs and a disk merge, including duplicates across partitions.
Temporary disk use scales with the XML and URL inventory; provision enough local
disk and monitor it. Validation and IndexNow planning use streaming reads and
private temporary spools. Submission summaries retain per-batch outcomes and
failures, so that metadata grows with request count. `Validator#each_entry` yields
only after the entire inventory validates. `Validator#validate!` collects entries by default for Ruby
callers; use `collect: false` when the list is not needed.

The low-level `Writer#write`, `Parser#entries`, explicit `to_a` calls, memory
storage, and app-owned arrays can still retain the whole inventory. Use
`Writer#each_file` or the normal generation operation for incremental output.
Custom adapters without `open`/metadata or `write_io` fall back to whole-file
reads/writes; each file is still bounded by the configured limits. There is no
full-document formatting pass during generation. Task reports use counts recorded
while writing rather than downloading published files again. Serialization may
differ from older Nokogiri-reformatted output while retaining XML meaning.

## Atomic publication and storage

Atomic mode is opt-in and requires `revision(root)` and
`publish(source, files:, root:, expected:)` capabilities. An unsupported adapter
fails before sources are evaluated. Existing six-method adapters keep legacy
sequential publication unless explicitly extended. Named outputs inherit atomic
mode and limits and can override them independently.

Both built-in persistent adapters upload immutable children before activating the
stable root. A root revision captured before generation must still match at
activation. Otherwise `Indexmap::SupersededPublication` is raised and that build
cannot overwrite a root published by another writer. Retry by rebuilding current
eligible data. Queue concurrency reduces wasted work but does not replace this
check, including for direct rake invocations.

Filesystem activation uses a per-root `flock` and same-filesystem atomic file
replacement. The destination must be a trusted local/shared filesystem with
working cross-process locks and atomic rename semantics. This is not a guarantee
for arbitrary NFS mounts or object-store filesystem gateways. Storage keys cannot
escape the configured root through traversal or existing symlinks. Published
immutable child keys cannot be overwritten through the built-in write APIs.

For Active Storage, keep the host-owned artifact model with `has_one_attached`
and a database unique index on its filename column. Install Active Storage through
Rails' installer and generate any host migration with Rails; inspect and remove
existing duplicate rows before adding that index. Indexmap does not invent host
migrations or modify attachment configuration. Example generator command:

```sh
bin/rails generate migration AddUniqueIndexToSitemapArtifactsFilename
```

Edit the generated migration to add the unique index after checking existing
schema and data; do not add a duplicate index if one already exists. Atomic mode
checks that an unconditional single-column unique index exists. Root blobs carry
the generation identifier in native Active Storage metadata and are uploaded
before a short host-record lock attaches them. Reading the active generation
requires no object-store download under that lock. Generation and uploads run
outside that database transaction. SQLite lock contention can raise a
transient database error; preserve the host's explicit retry policy.

The adapter archives the previous atomic sitemap index before activation. Archive ownership
proves that a retained child's generation was published; uploaded orphans are
excluded from shared HTTP delivery. Old children remain available for cached
roots. Active Storage archive age follows the artifact record, not the older
blob's creation date. The model's normal attachment lifecycle handles purging
when expired artifact records are destroyed. Ensure its purge jobs have workers;
use the host's existing unattached-blob cleanup for uploads interrupted before
an artifact could be attached.

Keep the destination shared by workers and every serving instance. A container's
`public/` directory is not automatically shared or persistent. In legacy mode,
validation failure preserves old artifacts, but interrupted sequential writes can
still leave mixed generations. Atomic mode solves that collection-level problem.

## Jobs and schedules

Generate the job in the host application, then edit it:

```sh
bin/rails generate job SitemapRefresh
```

```ruby
require "indexmap"

class SitemapRefreshJob < ApplicationJob
  retry_on Indexmap::SupersededPublication, wait: :polynomially_longer, attempts: 3

  def perform(_version = nil)
    IndexmapConfiguration.apply
    Indexmap::TaskRunner.new.create
  end
end
```

Load the host configuration file first if it lives outside an initializer. The
explicit require above makes the exception class available when a job is
eager-loaded; it does not evaluate section sources. The host's `ApplicationJob` context,
authorization, and transaction hooks remain authoritative. Pass scalar output or
release identifiers and enqueue after source transactions commit and database
preparation completes. A separate queue database is not transactionally coupled
to application data.

The same body works with GoodJob and Solid Queue. Keep the adapter-specific
concurrency declarations and recurring schedules in the host; see the
[GoodJob and Solid Queue examples](../README.md#background-generation). Use a
shared execution key/label across releases for the same destination. Solid Queue
uses a shared concurrency group too if multiple job classes write that destination.
Prefer blocking/rescheduling to discarding a newer refresh. Choose a concurrency
duration above measured runtime and remember it can expire. Direct `perform_now`
and rake calls bypass queue coordination but still use atomic activation checks.

Use one enqueue owner per trigger. Avoid duplicate startup/release scheduling,
per-country fan-out, and continuations until actual runtime justifies them. Retry
identified transient storage/database errors deliberately; do not repeatedly retry
invalid configuration or content. `after_create` callbacks run after publication
and must be safe to repeat. A callback failure does not roll publication back.

`TaskRunner#create` runs default-output callbacks and key-file handling.
`Indexmap.create(:name)` generates a named output without those callbacks. Keep
that distinction when designing independent refresh jobs. Generation does not
submit to IndexNow; keep sending as a separate operation so refresh retries do
not resend successful batches.

## Serve published XML

Require the controller and explicitly mount the root and generated child pattern.
This example assumes root-level storage keys and `index_filename = "sitemap.xml"`:

```ruby
require "indexmap/sitemaps_controller"
IndexmapConfiguration.apply

Rails.application.routes.draw do
  get "/sitemap.xml", to: Indexmap::SitemapsController.action(:show),
    defaults: {filename: "sitemap.xml"}, format: false
  get "/:filename", to: Indexmap::SitemapsController.action(:show),
    constraints: {filename: /sitemap-[a-f0-9]{16}-[a-f0-9]{32}-[1-9]\d*-[1-9]\d*\.xml/},
    format: false
end
```

Mount named roots explicitly too. For nested keys, set the full root key in the
route defaults and a fixed `prefix` default for child routes. For example a
`/sitemaps/:filename` child route can use `defaults: {prefix: "sitemaps"}`. Only
path parameters are used, so query strings cannot supply a storage prefix. Dots
must be accepted by the filename constraint; disabling format parsing alone does
not make Rails dynamic segments accept dots. Do not mount a broad catchall route.

The controller allows configured roots and existing children from current or
archived atomic publications. It never resolves section providers. Other files,
archive indexes, and unpublished orphan children are excluded. Delivery requires
storage `metadata` and `open` capabilities, implemented by both persistent
adapters. The endpoint uses `application/xml`, streams bodies, and supports HEAD,
ETag, Last-Modified, and 304. Roots cache for ten minutes with one hour of stale
revalidation; immutable children cache for a year. Generation authorization uses
the host's Rails cache keyed by the current root's metadata. Authentication,
visitor tracking, and browser gates from host controllers are not inherited.

When switching from legacy child names, keep the old allowlisted child routes
or static files through the cached-root/rollback grace period. Atomic mode does
not rename or prune those legacy files automatically, and the new shared
controller does not authorize arbitrary legacy children. Add the generated child
route first, enable atomic publication, and retire legacy serving only after the
transition period. Then remove the old child artifacts deliberately.

Remove static files that would shadow these routes, or deliberately keep static
serving and configure its root/child cache headers appropriately. Robots is a
separate opt-in endpoint; see [dynamic robots](../README.md#dynamic-robots).
Public origins must come from configuration, not request headers. Storage public
URLs must be the URLs that the app actually serves, not private object-store URLs.

## Retention and operations

```sh
bin/rails indexmap:sitemap:create
bin/rails indexmap:sitemap:validate
RETENTION_HOURS=48 bin/rails indexmap:sitemap:prune
```

Schedule pruning separately from generation. The default grace period is 48 hours;
values below one hour are rejected. Choose a period longer than the oldest root
that your caches can still serve, including stale revalidation and deployment
rollbacks. Retention is an operational policy, not a promise about arbitrary
crawler caches. Pruning is locked against activation, preserves the current
publication, removes expired archives and unreferenced owned children, and leaves
other outputs and unrelated files alone. Failed-build orphans age out too.
Active Storage pruning destroys owned artifact records and delegates blob cleanup
to normal attachment jobs, avoiding object-store deletes under the root lock.

Do not use an old app callback that deletes everything outside configured section
filenames: atomic child names deliberately differ. Replace it with the gem's
prune task when adopting atomic mode. The format task refuses to run when an
atomic output is configured. Regenerate instead of mutating immutable XML.

For IndexNow selection, exact attempt exports, timeouts, and bounded retries, see
[search-engine submission](search-engine-ping.md#ping-indexnow). A missing timestamp
is not evidence of a content change, and removal from a sitemap is not evidence
of deletion. Durable history and automatic inventory diffs are not implemented.

## Host adoption

Release and consume the gem before removing host implementations. Local path
overrides are for verification only and must not be committed to applications.

- Reviato: keep editorial/indexing policy and GoodJob scheduling. Verify the
  existing artifact filename index, remove the old prune callback when enabling
  atomic mode, and replace fixed child-name routes with explicit root/generated
  routes. Keep application permission and system-context checks in host tests.
- Places: keep `Place.indexable`, directory thresholds, canonical path generation,
  and the daily schedule. Replace manual staging/promotion/cleanup with the gem
  operation, choose shared persistent storage, and use gem partitions rather than
  materializing and slicing all country entries. Preserve robots exclusions and
  explicit production/preview policy. Remove static XML or configure static
  serving deliberately before enabling the controller.
- Nuntio: retain the database-free build for static marketing content. Only add a
  runtime refresh when there is a real public database source. Keep private
  publishing records excluded and use the marketing indexing flag for robots.

Validate actual public root/child URLs, headers, key verification files, workers,
and queue failure reporting in each host. Gem integration tests exercise real
GoodJob, Solid Queue, and Active Storage against PostgreSQL; they do not prove a
particular application's deployment wiring.

## Integration checks from a source checkout

The integration harness creates a temporary Rails app and runs framework/gem
installers and generators. It drops and recreates the supplied `indexmap_test`
database. Never point it at an application database.

```sh
BUNDLE_GEMFILE=gemfiles/integration.gemfile bundle install
INDEXMAP_DATABASE_URL=postgresql://postgres@localhost/indexmap_test \
  BUNDLE_GEMFILE=gemfiles/integration.gemfile bundle exec ruby script/integration
```

The harness checks the real GoodJob adapter, a running Solid Queue worker,
validation failure visibility, shared filesystem output, Active Storage activation,
and archive retention. CI provides a disposable PostgreSQL service. No external
search-engine requests are made.

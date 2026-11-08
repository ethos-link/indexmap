# Upgrade Guide

Use this guide when upgrading an application that already generates, validates,
or pings sitemaps with `indexmap`.

Run `bundle exec rake verify` locally before pushing or preparing a release.
GitHub Actions runs commitlint and release packaging/publication only.

## Next

### Explicit IndexNow entries

`Indexmap::Pinger::IndexNow#ping` and `.ping` now accept `entries:` containing
`Indexmap::Entry` objects. Existing calls without this keyword retain sitemap
selection. An explicit list submits only those URLs without reading sitemap
files or applying date filters. Empty lists skip
submission. Replace app-owned IndexNow HTTP clients with this API. Prefer
independent queued deliveries per provider and URL, raising retryable failure
results into the host queue policy. A per-provider delivery table is optional,
not required; larger batches can use per-attempt receipts to retain progress. See
[direct change submission](docs/search-engine-ping.md#submit-known-changes-directly).

### Sitemap origin override

The generated initializer and task examples now use `BASE_URL`. In existing
initializers, replace `ENV.fetch("INDEXMAP_BASE_URL", ...)` with
`ENV.fetch("BASE_URL", ...)`, and update CI commands, scripts and environment
settings that supply the old name. Keep the app's default origin and lazy
configuration. The installer preserves authored initializers; it does not rename
the variable in an existing app.

For example, run `BASE_URL=https://example.com bin/rails indexmap:sitemap:create`.
The initializer owns this convention; the gem does not read either variable
outside that configuration.

### Rails configuration without a host loader

The installer now generates `ActiveSupport.on_load(:indexmap)` around the existing
`Indexmap.configure` block. It works when tasks load the gem before initializers
and when jobs first require it after boot. Plain Ruby `Indexmap.configure` is
unchanged. Existing host loaders continue working until migrated.

For an existing app:

1. Keep the app's configure block in `config/initializers/indexmap.rb`, wrapped in
   `ActiveSupport.on_load(:indexmap) do ... end`. Remove the surrounding host module,
   mutex, `@applied` guard, and bottom-of-file apply call. Do not keep both owners.
2. Keep `base_url`, storage construction, route calls and source queries lazy.
   Use `config.storage = -> { Indexmap::Storage::Filesystem.new(path: ...,
   public_url: config.base_url) }`. The previous template evaluated the origin at
   boot, which fails when it needs unloaded routes or later initializer settings.
   An `after_initialize` wrapper is not a substitute for deferring evaluation.
3. Replace host-loader calls in models, jobs, routes and scripts with `require "indexmap"`
   before the gem operation. Remove any separate configuration-file loads.
4. Use one `require "indexmap/tasks"` in the Rakefile before application loading.
   Rakefiles are not web/worker boot paths; argument-sensitive loaders and duplicate
   task files are unnecessary. The installer preserves existing loaders and
   authored initializer content; migrate those manually rather than overwriting.
5. Verify web/worker boot, Rails task listing, create/validate via Rails and Rake,
   a real refresh job, and HTTP delivery against the same configuration.

### Adopt the publication pipeline

Use built-in storage instead of copying file writes and promotion into the host.
`TaskRunner#create` stages, partitions and validates before publishing. Remove
outer staging directories, repeated validation, manual URL-count partitions,
and whole-inventory arrays where the host can supply lazy entries. Keep domain
eligibility, canonical paths, grouping and meaningful `lastmod` in the app.

For mutable indexes, use atomic publication to avoid mixed generations. Adopt
`config.atomic = true` together with persistent shared storage, routes and cache
policy for generated children, bounded retries for superseded builds, and a
separate prune schedule. Remove filename-based cleanup and retention callbacks;
they can delete immutable children referenced by cached roots. Single-file build
outputs can keep their existing delivery. See [deployment](docs/deployment.md)
and [dynamic sitemaps](docs/dynamic-sitemaps.md) for the complete contracts.

### UTF-8 output

Sitemap text is converted to UTF-8 before XML escaping and byte partitioning.
Invalid or unconvertible strings raise `Indexmap::ValidationError`. The validator
also rejects XML documents that declare another encoding, even when their XML is
otherwise valid. Regenerate older non-UTF-8 files before validating or submitting
them. Existing UTF-8 output and partition names are unchanged.

## 0.10.0

### Shared development and release tooling

Use Ruby 4 and published Gemkit 0.3.1. Install the bundle and hooks, then run the
project's verification command from the README. Prepare releases from clean,
current main; merging the generated release PR publishes through Actions.
See the [Gemkit upgrade guide](https://github.com/ethos-link/ethos-gemkit/blob/main/UPGRADE.md)
for workflow permissions and registry setup.

Rails integration, where provided, requires host-installed Rails 8. Plain Ruby
entry points remain available without Railties.


### Host loader and rendered artifacts

The install generator now defines `Indexmap::HostConfiguration.apply` instead of
`IndexmapConfiguration.apply`. When adopting the new template, move the existing
loader into `module Indexmap; module HostConfiguration; ...; end; end` and update
its bottom-of-file apply call, route mounts, jobs, scripts, and tests. Keep the
existing configure block, mutex, and idempotent `@applied` guard. Inside the new
namespace, qualify host constants that overlap gem names (for example `::Entry`
for a host model, versus `Indexmap::Entry` for a sitemap value). Use:

```ruby
Indexmap::HostConfiguration.apply if defined?(Indexmap::Configuration)
```

An existing host-owned loader can continue running while you migrate: the gem
never calls it by name. Do not mix old and new loader modules, as each has its own
application guard. Apply the host configuration before creating an operation.

The rendered file value is now `Indexmap::Artifact`, replacing
`Indexmap::Storage::File`. Its `filename`, `body`, `content_type`, and `basename`
interface is unchanged. Update custom adapters, type checks, and direct
constructor calls; replace internal `require "indexmap/storage/file"` with
`require "indexmap"`. The old constant and require path are removed. `::File`
always means Ruby's filesystem class.

### Storage resolution and publication lifecycle

`Creator`, `TaskRunner`, `Validator`, and pinger instances now resolve a storage
callable lazily once and retain that adapter. Nested generation, validation,
IndexNow key handling, and submission share it. Create a fresh operation instance
after changing storage configuration or tenant/context; do not reuse a runner or
pinger across different destinations. `Indexmap.create` already creates a new
creator each time. The optional `storage:` constructor keyword selects an explicit
adapter. Direct reads of `config.storage` still resolve the callable each time.

Filesystem publication now copies validated files and the previous root into
private `.indexmap-builds/` staging on the destination filesystem, outside the
per-root lock. Short locked sections create the staging lease and activate files
with same-filesystem renames. Keep that private directory writable and exclude
hidden paths from static HTTP serving. Allow disk space for source staging,
destination staging, and retained generations. Do not remove active staging
directories manually. Pruning reclaims abandoned staging after its grace period
and skips directories whose build lock is held; returned deleted paths can now
include these private directories. Normal failures remove staging immediately.

Filesystem listing now scopes traversal by the literal prefix's directory and
leading filename fragment. It excludes symlinks and hidden paths, including
private staging, and requires normalized relative prefixes (no traversal,
absolute paths, or redundant separators). Replace any reliance on symlink entries with actual keys under the storage root. A listing without a
prefix still intentionally scans the complete visible tree.

Atomic Active Storage checks the expected revision before uploading and again
before each upload. A failed or superseded build destroys its newly created child
records and purges its blobs immediately, including a partial upload whose blob
was saved before the service failed. Uploads and cleanup stay outside the root
row lock. A committed root is preserved even if a host `after_commit` callback
raises. Activation also checks that children still exist, so pruning an unusually
old in-flight build aborts it rather than publishing missing children.

Concurrent builds can still perform some speculative uploads before one wins;
optimistic publication cannot avoid work already in flight. Process death and
storage outages can also prevent immediate cleanup. Keep scheduled pruning,
unattached-blob cleanup, and working attachment purge jobs. A
`Indexmap::PublicationCleanupError` reports cleanup failures through `failures`
(each contains `artifact` and `error`), with the original publication exception as
its cause. Retain those private diagnostics; a failed service deletion can require
cleanup by object key even when Active Storage already removed the blob row.


### Task loading, parsing, and documentation

For an existing lazy installation, edit the generated Rakefile loader to check
Rake's collected tasks as well as `ARGV` (Rails removes the command from `ARGV`
before loading the Rakefile):

```ruby
indexmap_tasks_requested = Rake.application.options.show_tasks ||
  ARGV.any? { |argument| ["-T", "--tasks"].include?(argument) }
require "indexmap/tasks" if indexmap_tasks_requested ||
  (Rake.application.top_level_tasks + ARGV).any? { |argument| argument.start_with?("indexmap:") }
```

Keep this block before `require_relative "config/application"`. The installer
preserves existing task loaders, so rerunning it does not replace a stale block.
Verify `bin/rails indexmap:sitemap:create`, `bin/rails --tasks`, and
`bundle exec rake indexmap:sitemap:validate`. The generated initializer now checks
`defined?(Indexmap::Configuration)` before applying settings and constructs the
filesystem adapter once inside `apply`. Apply those edits to existing initializers
if needed, together with the host-loader rename above.

`Parser` remote children and redirects must now keep the explicit source URL's
scheme, host, and port; userinfo is rejected. Cross-origin references raise
`Indexmap::ValidationError` before their target is requested. To inspect a deployed
sitemap through a local origin, use `rebase_remote_children: true` deliberately;
this rebases child references, not redirects. Pass only trusted remote root URLs:
the parser is not an SSRF filter for arbitrary user-supplied roots or DNS results.
Remote responses and local files are capped at 52,428,800 bytes per document, and
DTDs are rejected. Streaming XML parsing can raise `Nokogiri::XML::SyntaxError`
for malformed XML that the older DOM parser recovered silently. Fix malformed or
oversized/DTD-bearing documents and cross-origin references before upgrading.
Storage-root parsing resolves children through storage and does not fetch remote
child URLs.

Use `Parser#each_entry` for incremental enumeration without the `entries` cache;
`entries` and `paths` still collect results. Google URL counting now streams XML
and uses temporary disk for exact deduplication. Provision temporary space for
that operation as well as generation/validation.

Create stages, validates, and publishes; it does not pretty-print. Only
`TaskRunner#create` and its rake task run callbacks and IndexNow key handling.
The optional format task remains for legacy output. See the
[deployment guide](docs/deployment.md) for static/dynamic sources and delivery,
robots policy, and development/production checks. Main documentation describes
features beyond your installed version; use documentation from its release tag.

### Generation, publication, and delivery

Generation now stages XML on temporary disk and partitions index sections by
`max_urls` and `max_bytes`. Defaults are the sitemap protocol limits. The first
legacy partition keeps its configured name; later files append `-002.xml`, etc.
Single-file mode still writes one file and fails if splitting would be required.
Locations must be shorter than 2,048 characters; repeated `loc`/`lastmod` fields
are rejected. Provision temporary disk for XML, validation spools, and duplicate
sorting. The full-document Nokogiri formatting pass is removed; XML meaning is preserved but
serialized bytes/checksums can change. Generation reports no longer download
published artifacts to count URLs.

Set `config.atomic = true` to opt into immutable generation children and guarded
root activation. Filesystem and Active Storage implement the required revision
and publish capabilities. Custom six-method adapters retain legacy behavior;
unsupported atomic mode fails explicitly. Generated child keys use a reserved
`sitemap-<owner>-<generation>-<section>-<part>.xml` namespace and cannot be
rewritten by built-in adapters. Update fixed filename route constraints, remove
static files that shadow new routes, and replace app cleanup callbacks that
recompute configured filenames. They would delete generated children.

Atomic Active Storage requires an unconditional unique filename index. Inspect
existing data/schema and use a generated host migration if needed. The host
artifact model remains app-owned. Retention uses archive record timestamps and
the model's normal attachment cleanup, which requires working purge-job workers.
Filesystem atomic mode requires shared lock/rename semantics; a worker-local
container directory is insufficient for multiple serving instances.

`Indexmap::SupersededPublication` means another build activated the root after
this build began. Retry by rebuilding; do not fall back to sequential writes.
Use native bounded Active Job retries in host jobs for this transient condition.
The same entrypoints support GoodJob and Solid Queue. The opt-in sitemap
controller serves configured roots and current/retained atomic children using
storage metadata and streaming reads. See [dynamic sitemap usage](docs/dynamic-sitemaps.md)
for routes, cache policy, adapter capabilities, and adoption steps.

Schedule `indexmap:sitemap:prune` separately. `RETENTION_HOURS` defaults to 48 and
must be at least 1; choose a grace period covering cached roots and rollbacks.
The format task refuses to mutate atomic publications; regenerate instead.

IndexNow selection now spools validated entries before sending, without retaining
all selected URLs. Optional bounded retries use `config.index_now.max_attempts`
(1..5, default 1) and `max_wait` (0..60 seconds, default 30). Attempt exports now
include attempt numbers. Long `Retry-After` values defer retries rather than
being shortened; this is not durable scheduling or exactly-once delivery.

Section entries are now consumed once per generation, including calculation of
the index's `lastmod`. Existing array sources keep the same XML meaning. Apps may
return fresh lazy enumerables from `config.sections`; do not reuse exhausted
one-shot sources between refreshes. Streaming generation and opt-in atomic
publication are described above.

Sitemap validation now rejects files larger than 52,428,800 uncompressed bytes,
URL sets and indexes with more than 50,000 entries, missing or incorrect sitemap
namespaces, DTDs, missing URL locations, cyclic indexes, unsafe child paths, and
child URLs outside the configured scheme, host, or port. Relative local child
references remain supported. Fix invalid existing files before upgrading.
Generation still validates before publication; sequential storage writes do not
provide atomic publication of the entire sitemap set.

IndexNow now validates the reachable sitemap before planning or sending. Duplicate
or otherwise invalid entries fail validation instead of being silently filtered.
Index sections partition automatically; use index format when a single-file
output would exceed its limits.

Date-only `lastmod` values now participate in IndexNow cutoff selection. Dates on
or after the cutoff's UTC calendar day are included, even when the cutoff has a
later time on that day. Missing dates remain included. Invalid `SINCE` still
raises and does not fall back to `INDEXNOW_RECENT_HOURS`. Batch sizes must be
integers from 1 through 10,000; malformed configuration is no longer truncated.

The new `indexmap:index_now:plan` task exports selection as JSON Lines without a
key or network submission. Existing dry runs still require a key. Set
`INDEXNOW_REPORT=1` on the ping task for JSON Lines containing attempt-started,
attempt-finished, and summary records. These are non-durable exports: save them
to private operator storage if needed, never public sitemap storage. HTTP 202
is reported as `validation_pending` in the attempt receipt. The summary retains
its existing `submitted` status for successful HTTP responses; it does not prove
indexing. Transport failures now appear in partial/failed results with reason
`unknown_delivery`, preserving earlier successful batches. Retries are opt-in as
described above; there is no durable delivery history.

Robots delivery is opt-in. Require `indexmap/robots_controller`, apply the host
configuration, and mount the controller explicitly as documented in the README.
Remove `public/robots.txt` when mounting it; static files can shadow Rails routes.
Crawling defaults to disabled. Configure an explicit predicate that also handles
staging running in production mode. The endpoint does not change host routes,
queue adapters, refresh jobs, or sitemap storage.

Search-engine ping tasks now treat `config.index_filename` as the authoritative
sitemap entrypoint. Google submits that sitemap once, and IndexNow recursively
reads the child sitemaps it references. Unreferenced `sitemap*.xml` files in the
configured storage are no longer submitted or included in IndexNow URL batches.

Before upgrading, ensure every current sitemap is reachable from the configured
root sitemap. If an application intentionally maintains an independent named
output, submit that output separately instead of relying on storage discovery.

## Upgrading To 0.6.x

Version 0.6.x routes every sitemap operation through the configured storage
backend. Generation, formatting, validation, parsing, Google submission,
IndexNow submission, and IndexNow verification files should all read and write
through the same storage object.

### 1. Configure Storage Explicitly

Set `config.storage` in the application initializer instead of relying on
implicit filesystem behavior.

For a Rails app that serves sitemap files from `public/`:

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = -> do
    Indexmap::Storage::Filesystem.new(
      path: Rails.public_path,
      public_url: config.base_url
    )
  end
end
```

For a production app that stores sitemap files elsewhere, point the storage
adapter at that production location and keep `public_url` on the public origin
where search engines fetch the files.

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://example.com" }
  config.storage = -> do
    Indexmap::Storage::Filesystem.new(
      path: Rails.root.join("storage/sitemaps"),
      public_url: config.base_url
    )
  end
end
```

### 2. Keep Relative Storage Keys Stable

If your app stores sitemap files under a directory, keep those directory
prefixes in `config.index_filename`, section filenames, and named output
filenames.

```ruby
Indexmap.configure do |config|
  config.index_filename = "sitemaps/sitemap.xml"
  config.sections = -> do
    [
      Indexmap::Section.new(
        filename: "sitemaps/sitemap-pages.xml",
        entries: Sitemap.pages
      )
    ]
  end
end
```

Do not work around older versions by stripping paths down to basenames. The
parser, validator, pingers, and filesystem adapter now preserve relative storage
keys such as `sitemaps/sitemap.xml`.

### 3. Update Custom Storage Backends

Custom storage backends must accept the documented `content_type:` keyword on
`write`. The format task rewrites XML files and passes the XML content type.

```ruby
class SitemapStorage
  def write(filename, body, content_type:)
    # Persist body under filename and store content_type when the backend
    # uses it.
  end

  def read(filename)
  end

  def exist?(filename)
  end

  def list(prefix:, suffix:)
  end

  def delete(filename)
  end

  def public_url(filename)
  end
end
```

### 4. Verify Development And Production

Run the same lifecycle tasks against the storage configuration each environment
will use.

Development:

```bash
bin/rails indexmap:sitemap:create
bin/rails indexmap:sitemap:validate
bin/rails indexmap:sitemap:format
```

Production or staging:

```bash
RAILS_ENV=production bin/rails indexmap:sitemap:create
RAILS_ENV=production bin/rails indexmap:sitemap:validate
RAILS_ENV=production bin/rails indexmap:ping
```

Before deploying, confirm:

- `config.base_url` is the public origin for the environment.
- `config.index_filename` identifies the public root sitemap and exists in the
  configured storage.
- The root sitemap references every current child sitemap. Unreferenced sitemap
  files in storage are intentionally ignored by the pingers.
- `config.storage.public_url(config.index_filename)` returns the fetchable root
  sitemap URL.
- `indexmap:sitemap:validate` passes against the same storage used by
  production.
- If IndexNow is enabled, the `<key>.txt` verification file is present in the
  configured storage or `config.index_now.key` is set.

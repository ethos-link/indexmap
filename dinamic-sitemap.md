# Dynamic sitemaps and IndexNow delivery

The agreed gem implementation is complete in the development branches, not yet
released. Usage and operating instructions are maintained in
[dynamic sitemaps](docs/dynamic-sitemaps.md), the [README](README.md), and the
[IndexNow guide](docs/search-engine-ping.md). Contract changes and host migration
steps are in [UPGRADE.md](UPGRADE.md). This document records the requirements and
rationale; it is not a second usage manual.

## Delivery status

| Capability | Implementation |
| --- | --- |
| Single provider/source pass | `Output` resolves only the selected source; `Writer` calculates dates during rendering. |
| Streaming and partitions | `Writer#each_file` bounds each XML file; `Creator` stages on disk and validates before publishing. |
| Streaming validation and duplicate checks | XML Reader traversal plus bounded sorted URL runs and disk merge. Validated enumeration spools before yielding. |
| Atomic generations | Optional revision/publish capabilities in Filesystem and Active Storage, immutable children, guarded root activation, and retained root archives. |
| Retention | Explicit prune operation and task; per-root coordination and ownership preserve current/other outputs. |
| Rails delivery | Explicit sitemap and robots controllers, no source queries, conditional responses, and streaming bodies. |
| IndexNow visibility and resilience | Exact selection/attempt exports, per-attempt receipts, timeouts, partial results, and opt-in bounded batch retries. |
| GoodJob/Solid Queue compatibility | Host-owned Active Job entrypoints; real adapter/worker integration checks using generated Rails setup and PostgreSQL. |
| Host adoption | Concrete steps documented. Removal of host implementations follows release/consumption of the replacement; no app path overrides or gem release are committed here. |
| Durable private history and inventory diffs | Intentionally deferred by the reviewed decision gates below. |

Indexmap owns mechanics. Apps retain eligibility, canonical routes, meaningful
content dates, refresh triggers, tenant/system context, and queue configuration.
No model DSL, route crawler, backend switch, or automatic model callback was
introduced.

## Current application requirements

All three applications pin Ruby 4.0.9 and Rails 8.1.4 and load Rails 8.1 defaults.
The reviewed source directories are `/home/fidalgo/workspace/2-reviato`,
`/home/fidalgo/workspace/nuntio`, and `/home/fidalgo/workspace/places`.

| Application | Current behavior | Requirements to preserve |
| --- | --- | --- |
| Reviato | `app/models/sitemap.rb` composes marketing, articles, and insight sections. Production artifacts use Active Storage; development uses filesystem storage. Controllers provide conditional HTTP caching. A GoodJob refresh runs on production worker startup. | Mixed file and database-dependent content policies; shared artifacts across containers; app-owned canonical routes and editorial gates; existing named-output support in Indexmap. |
| Places | `Place.indexable` selects public records with sufficient assessment and fresh evidence. `Sitemap` builds country sections and directory aggregates. A custom storage adapter, refresh job, middleware, and robots controller fill infrastructure gaps. | Exclude closed, stale, draft, and low-signal places. Require at least three eligible places for directory groups. Preserve Unicode paths, country partitioning, daily refreshes, and deploy-time availability. |
| Nuntio | `MarketingSitemap.paths` reads an explicit route manifest and translated marketing content. Docker builds a single public sitemap. Robots is a static file. | Keep static generation independent of a database. Exclude account and publishing workflows. Use the configured marketing origin and respect the explicit marketing indexing flag. |

Nuntio currently has no database-backed sitemap source. Its private publishing
records are not candidates merely because they exist in the database. Future
public database content needs an application-owned source and eligibility scope.

Reviato's `Insights::IndexingPolicy` currently excludes hubs, benchmarks, and
market pages. Its article inventory reads published content artifacts. Supporting
database sources must not accidentally enable excluded insight surfaces.

Places' production sitemap files live in the application container's `public/`
directory. Its persistent volume covers `/rails/storage`, not `public/`. A
separate worker cannot safely refresh those files without shared storage or a
change to where the web process serves them from.

## Findings before implementation

| Finding | Evidence and consequence |
| --- | --- |
| Providers run more than once | `Output#writer` resolves the selected source twice and the unused source once. A probe observed two section-provider calls per generation. `Writer#section_lastmod` also traverses section entries again; a lazy enumerable can re-execute. App-side memoization may hide some repeated queries but does not fix the gem contract. |
| Generation retains the full inventory | App arrays, writer strings, formatted Nokogiri documents, and parsed validation entries can coexist. Places batches database reads but accumulates all resulting entries. Batching reads alone does not bound total memory. |
| Protocol limits are missing | A probe successfully generated a sitemap with 50,001 URLs. The validator needs entry and uncompressed-byte limits for both URL sets and indexes. |
| Child references are insufficiently validated | A probe accepted an off-origin child reference when a corresponding local file existed. Public child URLs need validation independently of page URLs. |
| Validator recursion has no cycle guard | Nested indexes recurse without tracking the active path. A self-reference or multi-file cycle can exhaust the Ruby stack. `Parser` has a visited set, but validation runs its own unguarded traversal first. |
| Publication is safe only before writes begin | `Writer` already orders children before the root; `Creator#publish` writes them sequentially. A simulated second-child write failure preserved the old index but had already replaced the first child. Root-last ordering alone does not preserve the collection. |
| Cleanup is application-owned | Reviato prunes unconfigured artifacts; Places removes stale country files. Neither policy expresses retained generations or ownership across independently refreshed outputs. |
| Web delivery is duplicated | Reviato serves artifacts and Places supplies robots and static-file cache policy. These are reusable capabilities, provided integration is explicit. |

The sitemap protocol requires UTF-8 XML, at most 50,000 URLs per URL set, and at
most 52,428,800 uncompressed bytes per sitemap. Index files have corresponding
entry and size limits. See the [sitemap protocol](https://www.sitemaps.org/protocol.html).

## Implemented decisions and rationale

### Bound data processing without a new service framework

The existing writer, creator, validator, and pinger remain the owners. Generation
holds a partition and bounded parsing/sort buffers rather than all XML documents.
File metadata grows with sitemap file count. App arrays and explicitly
inventory-returning APIs remain caller-owned memory costs. Temporary disk grows
with the document/URL inventory and is cleaned when operations finish or raise.

XML Reader consumes fields directly without building a document per URL. Sorted
10,000-URL runs and a two-way disk merge preserve duplicate rejection across
partitions without an inventory-sized Set. Generation reports reuse writing
counts. There is no repeated full-document formatting pass or final-artifact
redownload solely to count links. The public `Writer#write` convenience API still
returns an array; the generation path uses its incremental counterpart.

Rationale: reusable Ruby enumeration and native XML/file APIs cover the required
work. Keep complexity at the actual storage/validation gap, not around Active
Record or Active Job. A synthetic filesystem run with 180,000 lazy entries
reduced peak resident memory from about 366 MiB to 53 MiB while preserving the
output checksum. This supports replacing the inventory-sized duplicate Set with
bounded disk runs; it is not a production capacity or runtime guarantee.

### Activate a complete publication

Atomic mode is explicit so custom six-method adapters keep working. Built-in
persistent adapters upload immutable children before activating a stable root.
A captured root revision must still match at activation. Concurrent losers raise
`SupersededPublication` and can rebuild; they cannot overwrite another root.
Filesystem uses a per-root file lock and atomic rename. Active Storage preuploads
blobs, then uses a short host-record lock; a unique filename index is required.
No generation/upload work runs inside that database transaction.

Previous roots are archived before replacement. This proves retained generations
were published and lets cached roots resolve children. Pruning uses retirement
age, excludes the current publication and other outputs, and ages out orphans.
Active Storage artifact destruction delegates purge work to normal attachment
jobs after the root transaction. No generic lock manager, journal, or new host
schema was introduced.

Rationale: root-last order alone cannot protect overwritten children. Immutable
children plus guarded activation provide the required boundary. Retained root
archives also prevent shared delivery from exposing unpublished orphan files.

### Keep HTTP serving configuration-only

Controllers are explicitly mounted and independent of host HTML/authentication
callbacks. They use configured origins, fixed MIME types, metadata-based
conditional responses, and streamed reads. Roots have a short TTL; immutable
children have a long TTL. Native Rails cache entries identify the active
generation by root metadata. Route parameters do not authorize arbitrary storage
keys, and dynamic source providers never run on GET or HEAD.

Rationale: no sitemap queries belong on crawler request paths. Static/CDN serving
remains available with a documented cache and storage contract. Host content
must still enforce its own authentication and indexing policy.

### Separate selection, attempts, and remote indexing

Selection exports explain each inclusion/exclusion without requiring a key.
Sending emits exact batch/attempt membership and outcomes. The full reachable
inventory validates before any URLs are yielded for sending; batches then stream
from a private temporary spool. These exports are not a durable ledger.

Date-only cutoffs include the cutoff's UTC calendar day. Missing dates remain
included. Retry limits are explicit, honor Retry-After within their wait budget,
and apply to transient failures in the affected batch only. HTTP 202 remains
validation-pending; timeouts retain unknown-delivery status in attempt output.
No successful receipt is labelled as proof of indexing.

Rationale: operators can see intent and attempts now without introducing a
private database or pretending retries are exactly-once. Generation and sending
remain separate so a refresh retry does not resend successful batches.

### Keep jobs portable

The same synchronous generation operation runs through each host's
`ApplicationJob`. GoodJob labelled limits and Solid Queue concurrency groups,
keys, durations, and conflict policy remain host choices. Native queue controls
reduce overlap but do not replace publication checks. No new job backend,
scheduler, worker lifecycle hook, fan-out, or resumable-job framework was added.

Rationale: the apps already have established adapters and deployment topology.
Real integration checks exercise both adapters, a Solid Queue worker, database
source selection, failure visibility, Active Storage activation, and retention.
Host-specific permission context and deployment smoke checks remain app-owned.

## Deferred decision gates

Durable attempt history still requires an explicitly chosen separate private
store with access, retention, replay, and crash semantics. Meaningful inventory
diffs additionally require trustworthy app-supplied per-URL versions; current
`loc`/optional `lastmod` do not establish that contract across all three apps.
Do not infer deletion from inventory disappearance, particularly when Places'
evidence eligibility expires. Do not add pending-notification outboxes or crash
reconciliation until those prerequisites are approved.

This deferral was part of the reviewed scope, not an unfinished implementation
of the current API. No history, diff, or deletion-notification capability is
advertised in the usage docs.

## Verification and adoption boundaries

Focused regressions cover protocol count/byte boundaries, source consumption,
malformed/foreign/cyclic/deep graphs, partition-spanning duplicates, interrupted
uploads, concurrent activations, output-scoped retention, symlink escapes,
conditional HTTP delivery, orphan exclusion, exact submission reports, and retry
limits. `script/integration` creates its Rails app through actual generators and
installers and uses a disposable PostgreSQL database. CI runs this integration
path separately from the normal Ruby matrix.

Reviato, Places, and Nuntio keep their existing app implementations until they
consume a released replacement. The adoption guide specifies routing, storage,
cleanup callback, cache, and worker checks, including preserving legacy child
routes through the cached-root transition. No gem publishing, application
migration, live IndexNow submission, or production deployment is performed by
this implementation.

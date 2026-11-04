# Dynamic sitemaps and IndexNow delivery

Status: correctness, selection visibility, and opt-in robots delivery are
implemented in the working tree, not released. See the README and
`docs/search-engine-ping.md` for current usage and `UPGRADE.md` for contract
changes. Streaming, atomic collection publication, and app migrations remain
proposed. The scope is reusable behavior for Reviato, Nuntio, and Places.

Indexmap should own sitemap generation, validation, publication, optional Rails
delivery, robots formatting, and inspectable IndexNow submissions. Applications
should own public-page eligibility, canonical routes, meaningful content dates,
refresh schedules, and queue configuration.

The design must answer two separate questions: which URLs are currently public
and indexable, and which URLs we actually attempted to send to IndexNow.
A sitemap read back through storage answers the first. An export of the current
selection answers what we intend to send next. Durable attempt history would
answer the second, but is deferred until a separate private store is designed.

Ship correctness fixes, non-durable selection export, and robots independently.
Streaming publication is a later opt-in capability. Durable receipts, inventory
diffs, and crash reconciliation are conditional future work, not prerequisites
for the first release.

## Implementation readiness and code budget

Increments 1a, 1b, and 1c below are implemented, together with transport timeouts
and partial-result preservation. Automatic retries remain deferred. The later
storage work is a direction with acceptance criteria, not a complete adapter
specification. Before implementing it, settle activation/locking semantics and
measure the actual pipeline. Durable history and content diffs remain deferred.

Use the following constraints to keep the implementation small:

- Extend the existing `Output`, `Writer`, `Creator`, `Validator`, and pinger
  owners. Do not introduce parallel runners, services, source registries, or a
  model DSL. Keep task bodies thin.
- Reuse the existing synchronous generation entrypoints from jobs and rake.
  Introduce no queue adapter abstraction, scheduler, polling loop, or worker hook.
- Extract one private selection method for preview and sending before considering
  a new plan class. Export rows incrementally; do not duplicate URL arrays in
  reports or job arguments.
- Use local variables for one invocation's resolved inputs. Do not memoize
  database sources across jobs or mutate global configuration around a run.
- Keep robots configuration minimal: enablement, groups, and sitemap roots.
  Do not implement a general crawler-policy language or robots parser.
- Add each optional storage capability only when a concrete supported adapter
  needs it. Do not design a generic filesystem/object-store framework up front.
- Keep sitemap responses at the known `application/xml` protocol type. Arbitrary
  stored MIME types do not justify a new metadata subsystem.
- Measure before adding caches, external sorting, parallel generation, incremental
  updates, or resumable job orchestration. Correctness and safe publication are
  requirements regardless of measurements.

Rationale: the reusable boundary is the operation and artifact contract. A shared
class for every application configuration choice would add more code than the
small host job it replaces.

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

## Proposed sitemap generation and publication

### Keep the existing manifest boundary

Retain `Entry`, `Section`, named outputs, and explicit configuration. Extend entry
sources to accept an `Enumerable` without converting the whole source to an
array. Resolve configuration and invoke each selected provider once per run.
Only evaluate the source relevant to the selected output and format.

Fix source resolution first without advertising streaming support. The later
writer must compute section counts and maximum `lastmod` while writing entries,
so index metadata never triggers a second traversal of a lazy source.

Applications should use Rails scopes, selected columns, SQL aggregates, and native
`find_each` or `in_batches`. Do not add an Indexmap model concern, automatic model
discovery, route crawling, or callbacks on every database update.

Rationale: the apps already own the query and routing decisions. A second query
DSL would duplicate Rails and obscure which records become public. Rails 8.1
already supports batching cursors; custom cursors need a unique tiebreaker and
stable columns. Concurrent writes can still affect a batch scan. See
[Rails 8.1.4 batching](https://api.rubyonrails.org/v8.1.4/classes/ActiveRecord/Batches.html).

Capture the run's clock for time-dependent eligibility. Do not claim a consistent
database snapshot merely because providers run once. Apps requiring that stronger
guarantee must supply a snapshot or database-appropriate read strategy; avoid
holding a database transaction open while uploading artifacts.

### Bound memory and enforce limits

Write XML incrementally to temporary files. Split before either the configured
URL threshold or the protocol byte limit is exceeded. Count the escaped UTF-8
output, including document overhead. Reject a single entry that cannot fit.
Places can retain its conservative 45,000-URL partition target.

Streaming must replace `Creator#format`'s full-document Nokogiri reformatting,
not wrap it. Validation, parser use, and task reporting must also stop flattening
the whole inventory before claiming bounded memory.

Capture counts and section maximum dates during writing and reuse them for
generation reports. `TaskRunner#sitemap_details` currently downloads each final
artifact to count links; avoid that second read on generation, especially with
Active Storage. Preserve standalone validation of existing artifacts. Profile
query count, peak memory, temporary disk, and storage reads/writes for the complete
operation rather than optimizing only the database iterator.

Preserve cross-partition duplicate rejection. Measure Places' representative
inventory, peak memory, and query counts before choosing a replacement algorithm.
External sorted merge is deferred until measurements justify its implementation
and disk cost. A Set proportional to all URLs is not bounded-memory validation;
retain an explicit measured memory limit until the complete pipeline is bounded.

Use deterministic source order and partition rules. Omit empty sections; reject
an empty root with a clear error rather than publishing it over a valid sitemap.
Validate namespaces, required locations, timestamps, filename collisions, child
origins, and allowed storage prefixes. Generated indexes should reference URL
sets; reject cyclic or unsupported nested index structures.

The first correctness release must add an active-path/visited traversal guard
and a clear `ValidationError` for cycles. Review any broader rejection of
previously accepted nested indexes separately and document compatibility effects.

Rationale: protocol safety and memory use must hold for the complete pipeline,
including validation, reporting, and IndexNow selection.

### Publish immutable children and replace the root last

Use generation-specific child filenames with a stable public root:

```text
Build staged sitemap files
  -> validate the complete generation
  -> upload immutable children
  -> atomically replace the stable root
  -> retain publication metadata
  -> remove expired, unreferenced generations later
```

Keep child files at an appropriate public sitemap location so their URL scope
still covers the pages they describe. Do not introduce a deep generation path
without considering sitemap location rules.

For filesystem storage, reuse Active Support's
[`File.atomic_write`](https://api.rubyonrails.org/v8.1.4/classes/File.html) for
stable-file replacement. It prevents readers seeing a partially written file;
it does not make multiple overwritten children a transaction or promise
power-loss durability. Immutable child names close the collection-level gap.

For Active Storage, finish child uploads before updating the stable root artifact.
Keep the host-owned artifact model and require a database uniqueness constraint
for its artifact identity. Avoid relying on a model uniqueness validation alone.

Keep the existing six-method storage contract: `write`, `read`, `exist?`, `list`,
`delete`, and `public_url`. Introduce documented optional capability methods for
streaming, publication, and metadata. Use `respond_to?` at this supported adapter
boundary to select capabilities; do not add runtime-version detection branches.
Existing adapters keep the legacy path. Explicit requests for atomic publication
must fail clearly when unsupported, rather than silently use sequential writes.
Document the opt-in and adapter migration in `UPGRADE.md`.

Coordinate activation through storage-level locking or revision checks. Reject a
superseded build rather than allowing an older job to overwrite a newer root.
Queue concurrency rules alone do not cover rake tasks or direct invocations.

The adapter specification must choose an actual primitive: for example a
same-filesystem lock plus atomic rename, or host-record locking around activation
after uploads. Every writer, including tasks, must participate. Define the
revision check, lock scope, abandoned-build cleanup, and behavior on contention
before implementing this mode. Avoid a long database transaction during
generation/upload. Do not claim distributed safety for process-local mutexes or
filesystem locks on storage that lacks the required shared-lock semantics.

Retain previous children for a documented cache and crawler grace period. Cleanup
must know the output and generation that own each artifact. Refreshing one named
output must not remove another output's files or submission state.

Rationale: interrupted uploads preserve the previous usable generation, cached
roots keep working, and cleanup has an explicit ownership boundary.

Before enabling this mode, address the existing contract traps:

- Generation-specific names change child `<loc>` values. Keep the `sitemap`
  prefix while task discovery uses that prefix, and update host route constraints
  such as Reviato's fixed child-name allowlist.
- `TaskRunner#format` rewrites every `sitemap*.xml` it finds. It must not rewrite
  retained immutable generations. Format staged artifacts before activation and
  define the existing task's behavior for published immutable files explicitly.
- Active Storage `delete` purges the attachment but leaves its host row. Define
  row retention separately and include stable-root uniqueness and any generated
  host migration steps in `UPGRADE.md`.
- Filesystem storage does not persist `content_type`; its returned write result
  is not a metadata store. Serve allowlisted sitemap artifacts as the fixed
  protocol type. Metadata capabilities should supply validators and artifact
  identity, not an arbitrary MIME-type abstraction.

## Dynamic generation with GoodJob and Solid Queue

Use one host-owned `ApplicationJob` for a full refresh. Its `perform` body loads
the host's existing Indexmap configuration and calls the same synchronous
operation as the rake task. The gem must not depend on either backend, switch
adapters, or conditionally include backend modules. Dynamic generation is a
fresh database projection in a job; it does not require rendering XML on GET.

For the default output, retain the existing call sequence:

```ruby
IndexmapConfiguration.apply
Indexmap::TaskRunner.new.create
```

The host loads its configuration file first where necessary, as Places does
today. `TaskRunner#create` includes the current callbacks and key-file handling;
`Indexmap.create(:name)` generates a named output without those task callbacks.
Preserve that distinction. Do not add a new refresh wrapper just to rename these
calls, or silently run default cleanup callbacks after a named refresh.

| Concern | GoodJob 4.22.1 | Solid Queue 1.7.0 |
| --- | --- | --- |
| Job body | The same host `ApplicationJob#perform` delegates to Indexmap. | The same host `ApplicationJob#perform` delegates to Indexmap. |
| Avoid overlapping queued refreshes | Keep the host's labelled `perform_limit: 1` rule with `apply_label: true`. | Use host `limits_concurrency to: 1` with a stable destination key and `on_conflict: :block`. |
| Conflict behavior | Running conflicts are rescheduled; execution order is not guaranteed. | Blocked work is retained; execution order is not guaranteed. Choose a duration above measured runtime; expiry can permit overlap. |
| Duplicate release enqueues | Reviato's separate release-labelled `total_limit: 1` rule limits unfinished work for that release. | Blocking does not provide the same deduplication. Do not emulate it with new gem state. |

Keep the shared execution key/label tied to the publication destination, across
releases. A release-specific key alone permits releases to write concurrently.
If multiple Solid Queue job classes write that destination, use a shared
concurrency group as well; the default group is the job class.
Do not use discard-on-conflict by default: it can drop the newest requested
refresh. Enqueue through `perform_later`; queue controls do not protect direct
`perform_now` or rake calls. Storage activation remains the final safety boundary.
These controls and their different semantics are documented in
[GoodJob 4.22.1](https://github.com/bensheldon/good_job/blob/v4.22.1/README.md#concurrency-controls)
and [Solid Queue 1.7.0](https://github.com/rails/solid_queue/blob/v1.7.0/README.md#concurrency-controls).

Keep schedules and queue names in the host. Preserve Reviato's worker/release
trigger, Places' daily schedule for time-based eligibility, and Nuntio's static
build until a public database source exists. Use one enqueue owner per trigger;
do not add both a release hook and a startup hook for the same refresh. Enqueue
after source transactions commit and database preparation completes. Do not
assume a queue in a separate database commits atomically with application data.

Pass only necessary scalar identifiers, such as an allowlisted output or release
identifier. Query current eligible data when the job executes. Do not serialize
relations, URL inventories, credentials, or request-scoped tenant context.
Preserve host `ApplicationJob` context/authorization hooks, particularly Reviato's;
verify recurring work can run with its intended system context.

Keep generation and IndexNow submission as separate operations. A generation
retry must not automatically resend successful IndexNow batches. Generation
errors must reach the queue rather than becoming successful summary values.
Use bounded native Active Job `retry_on` for identified transient generation
errors only, after inspecting host/backend retry settings. Configuration and
validation failures need correction, not repeated execution. Avoid stacking job
retries around all-batches submission retries. See the
[Rails 8.1.4 retry API](https://api.rubyonrails.org/v8.1.4/classes/ActiveJob/Exceptions/ClassMethods.html#method-i-retry_on).

Workers must publish to storage visible to every serving instance. Generation
may run on a single worker initially; per-country jobs, continuations, and fan-out
are deferred until measured runtime requires them. A retry can rebuild the
projection once publication is repeatable and interruption-safe.

Verify the same refresh behavior through both real adapters: enqueue and execute,
overlapping refreshes, failure visibility, and a later retry after interrupted
publication. Use isolated queue databases and controlled fixtures. Gem tests own
generation/publication; a small host integration test owns configuration loading,
callbacks, authorization context, and serving the resulting artifact. The test
adapter alone cannot prove backend concurrency or shared-storage behavior.

## Optional Rails delivery and robots

Robots can ship independently of storage redesign. Provide an explicitly mounted,
namespaced robots controller driven only by configuration. Add sitemap delivery
after publication metadata is available. Keep direct filesystem/CDN delivery
available. Public endpoints must not perform content queries or generate XML.

Sitemap delivery should allow GET and HEAD, resolve only artifacts recorded in
published or retained generations, return correct content types, and support
ETag, Last-Modified, and 304 responses. Read metadata before downloading bodies.
Never interpolate unchecked request paths into storage keys.

Reuse Rails `fresh_when` and `expires_in`. For large Active Storage artifacts,
use native streaming/proxy facilities rather than an unconditional full download.
These APIs already cover HTTP caching and chunked storage reads:
[conditional responses](https://api.rubyonrails.org/v8.1.4/classes/ActionController/ConditionalGet.html),
[blob downloads](https://api.rubyonrails.org/v8.1.4/classes/ActiveStorage/Blob.html#method-i-download).

Keep these controllers independent of host login redirects, visitor tracking,
locale selection, HTML layouts, and browser-version gates. Mounting remains an
explicit host decision and must have host integration coverage.

Robots configuration should accept an indexing-enabled predicate, user-agent
groups, app-owned allow/disallow paths, and public sitemap roots. Reject injected
line breaks or control characters in individual values. Build sitemap references
from configured canonical URLs, never request headers.

Use an explicit environment policy: production-mode staging must be able to
disable crawling. Nuntio can reuse `marketing_indexable`; Places currently checks
only `Rails.env.production?`. Remove a static `public/robots.txt` when activating
a dynamic route so static delivery cannot shadow it. The install generator also
defaults sitemap output to `public/`: move those files or keep static serving
deliberately when mounting sitemap routes. Cache robots briefly and
keep it independent of database or object-storage availability.

Rationale: one implementation can format and serve crawler policy, while each
app still decides what that policy permits. Robots does not replace authorization
or page indexing directives. See [RFC 9309](https://www.rfc-editor.org/rfc/rfc9309.html#section-3).

## IndexNow behavior before implementation

The relevant owners are `lib/indexmap/pinger/index_now.rb`,
`lib/indexmap/pinger/base.rb`, `lib/indexmap/index_now_configuration.rb`, and
`lib/tasks/indexmap_tasks.rake`.

| Current behavior | Operational consequence |
| --- | --- |
| The configured root is parsed recursively through storage. Unreferenced XML files are ignored. | We can explain the source inventory, but an independent named output is not automatically included. |
| Without a cutoff, every reachable URL is selected and deduplicated by URL. | Repeated runs can submit the same unchanged inventory. |
| A nonblank `SINCE` takes precedence over `INDEXNOW_RECENT_HOURS`. Invalid `SINCE` raises; it does not fall back to recent hours. Timestamp entries are included when `lastmod >= cutoff`. Entries without `lastmod` are always included. | A recent-only run is not a precise change list. Nuntio's entries have no `lastmod`, so all are selected on every run. |
| Date-only `YYYY-MM-DD` values pass `Validator` through `Date.iso8601` but fail the pinger's `Time.iso8601` and are excluded under a cutoff. Invalid dates are also skipped. | Writer-generated `Date` values can be accepted as valid sitemap data and then silently excluded from recent submissions. Selection and validation disagree. |
| The default batch size is 500; overrides use permissive integer conversion. Zero reaches `each_slice(0)` and raises. | Invalid or overlarge settings need explicit validation before any request. |
| Key loading precedes selection and dry-run handling. A missing key returns `skipped`. | Planning without a key is a proposed behavior change, not an existing dry-run capability. |
| Dry runs and ordinary task output report counts. | Operators cannot inspect the exact selected URLs, batch contents, or selection reasons from the result. |
| HTTP success becomes `submitted`; successful response codes are discarded. | A response awaiting key validation cannot be distinguished from HTTP 200 later. |
| No durable URL-level plan or attempt history is written. A network exception escapes the batch loop before summarization. | Earlier successful batches disappear from the caller's summary too; historical counts cannot reconstruct exact payloads or uncertain delivery after a timeout. |
| Selection reads only the current sitemap. | URLs removed from the inventory cannot be notified through this path. |

The inspected app refresh jobs generate sitemaps; they do not themselves call
IndexNow. Reviato configures a key. No explicit IndexNow key configuration was
found in Nuntio or Places in the inspected configuration, jobs, and tasks. This
does not establish whether deployed keys or external submission schedules exist.

IndexNow accepts added, changed, and deleted URLs, allows up to 10,000 URLs per
POST, and distinguishes HTTP 200 from HTTP 202 with key validation pending.
A successful response establishes receipt, not indexing. A key under a directory
also constrains the URL paths it covers. See the
[IndexNow protocol](https://www.indexnow.org/documentation).

## Proposed IndexNow selection and delivery

### Export the current selection without adding a ledger

Add a planning operation that makes no network requests and exports exact selected
URLs with source output, source sitemap, `lastmod`, selection reason, and proposed
batch number. Include exclusion counts and reasons, the resolved absolute cutoff,
and whether submission would be blocked by a missing key or disabled policy.

Planning without a key is an explicit new capability. Keep actual submission's
key requirement. Reuse one selector between planning and submission, and support
JSON Lines plus a human-readable summary. Do not add persisted plan identities,
digests, stale-plan rejection, replay, or a history command in this increment.

Proposed command shape, not an available command:

```sh
bin/rails indexmap:index_now:plan > /private/operator-path/indexnow-plan.jsonl
```

The destination is operator-owned private storage outside `public/` and outside
the sitemap adapter. The gem writes to stdout and makes no durability claim.
A preview describes that invocation's inventory; a later submission can differ
if files or configuration change. It is not proof of an actual request.

For actual submissions, expose exact batch membership through a structured
result or optional streaming output tied to each attempt. Mark selected,
attempt-started, received, failed, unattempted, and unknown outcomes explicitly.
Keep keys and credential-bearing payloads out of output. Preserve existing
summary keys for callers and document any additional output contract.

Rationale: selection export solves the immediate inspection problem without a
private-store dependency. Attempt output shows what the current process did;
operators must retain it themselves until durable history is implemented.

### Fix date and batch validation before adding delivery infrastructure

Define the cutoff behavior for valid date-only sitemap values explicitly. Use
`Date.iso8601` for an exact `YYYY-MM-DD` value and compare it to the cutoff's UTC
calendar date, including the cutoff day. Use timestamp comparison for values
with a time. This conservative day-level policy avoids silently missing a change
whose time is unknown; test and document the extra same-day inclusions.

Retain `SINCE` precedence, its error on invalid input, and current inclusion of
missing `lastmod` values. Explain those selections in the export. Validate batch
size as an integer from 1 through 10,000 before sending any request. These fixes
need focused regressions and explicit upgrade notes where observable selection
or accepted configuration changes.

Rationale: correcting known inputs does not require content fingerprints,
publication generations, an outbox, or a database.

### Preserve partial results and bound request failures

Add explicit connect/read timeouts and handle expected transport exceptions at
the batch boundary. Preserve earlier batch results if a later request fails.
Distinguish HTTP 200 receipt from HTTP 202 pending key validation. Keep errors
bounded and sanitized. Do not convert arbitrary programming errors into a
successful or skipped run.

Add bounded retries as a separate verifiable increment. Retry rate limits and
transient server/transport failures with backoff and jitter; honor `Retry-After`
when supplied. Do not retry ownership/validation errors or HTTP 202 as ordinary
transient failures. Retry only the affected batch during the current invocation.
Do not claim retry across process restarts without durable state.

A timeout after sending can leave receipt unknown. A repeated request may be a
duplicate. The contract permits at-least-once attempts with visible uncertainty;
it cannot promise exactly-once receipt, crawling, or indexing.

Rationale: timeouts and partial-result preservation can ship using the existing
storage contract. They should not wait for inventory diffs or crash reconciliation.

### Defer durable history until a private store is specified

No current adapter provides a privacy flag, transaction, lock, metadata lookup,
or streaming contract. The generator normally writes into `public/`. Sharing
that store with receipts risks public exposure and collisions with broad sitemap
formatting and text-key discovery. Durable receipts require a separately
configured private store with access control, retention, and crash semantics.

Revisit the ledger only after selecting that store and demonstrating the need for
cross-process history or retries. Its minimum useful records would include exact
ordered batch membership, selection reasons, attempt times, endpoint, HTTP status,
and unknown-delivery states. Record intent before sending and outcome afterwards.
Never store the API key, credential-bearing payload, or key-bearing verification
URL in ordinary receipts or logs.

Use native Active Support instrumentation for optional process-level events;
it does not establish durable history. A Rails database implementation, if chosen,
needs real generated schema and explicit host migration instructions. Basic
static sitemap users must not acquire a required database.

Rationale: history is valuable, but the storage and lifecycle must earn their
place before introducing plan identities, replay, and stale-plan rules.

### Defer inventory diffs until applications supply meaningful versions

Current sitemap entries provide `loc` and optional `lastmod`. They do not supply
a reliable per-URL content-version contract across these apps. Before proposing
changed-only delivery, determine which public changes each app needs to detect
and verify the version input that actually changes with that content.

For Nuntio, missing timestamps prevent cutoff-based change detection; evaluate
versions from relevant public content inputs. For Places, verify whether
`updated_at` covers public association-derived content. Reviato retains its
publication and editorial gates. Do not manufacture `lastmod` from refresh time
or fetch every public page to compute differences.

Only revisit inventory comparisons after those inputs and a private store exist.
The later design must define baseline adoption, missing-version behavior, pending
failed notifications across unchanged generations, and crash recovery between
publication and notification scheduling. None of those mechanisms is part of the
first implementation brief. Preserve explicit full-inventory and cutoff modes.

Rationale: a sitemap inventory can identify membership changes, but cannot prove
meaningful content changes without trustworthy app-owned version data. IndexNow
prefers meaningful recent changes over routine full-site resubmission. See the
[IndexNow FAQ](https://www.indexnow.org/faq).

A URL disappearing from a sitemap does not prove deletion. Places' evidence can
age or an editorial gate can change while the resource remains public. Never
send automatic deletion notifications from inventory disappearance. Confirmed
deleted or redirected URLs may later be supplied explicitly by app policy,
without returning them to the sitemap. Reasons remain local metadata; the wire
payload is still a URL list. See the [IndexNow FAQ](https://www.indexnow.org/faq).

## Security, runtime, and compatibility

Validate canonical origins independently of requests. Keep public controllers
local to configured storage; do not expose the existing remote parser through
request parameters. Remote parsing, if retained for explicit tooling, needs its
own destination, redirect, timeout, and response-size policy.

Check XML byte limits before parsing, use explicit strict/non-network parsing,
and reject DTDs rather than enabling external entity or DTD loading. Bound index
traversal as well as detecting cycles; a long acyclic chain can exhaust recursive
validation too. Keep storage roots deployment-controlled and reject keys escaping
them, including symlink escape where a filesystem root contains symlinks. Robots
and sitemap responses must not create sessions or leak authenticated content into
public caches. Actual IndexNow attempt exports contain only validated public URLs.

Validate IndexNow URLs and ownership scope before sending, including when reading
existing files. Require an explicit submission-enabled policy for production-mode
previews. Treat endpoint overrides as trusted deployment configuration, never
request input. Avoid automatic public URL fetching as part of diff generation.

Indexmap advertises Ruby >= 3.2 and Rails components >= 7.1; its CI matrix now
includes Ruby 4.0 alongside 3.2 and 3.4. Do not silently raise minimum versions
as part of this work. Verify any
new API against the supported version matrix. The reviewed app pins align with
[Ruby 4.0.9](https://www.ruby-lang.org/en/news/2026/10/23/ruby-4-0-9-released/)
and the [Rails stable release information](https://rubyonrails.org/).

Preserve the existing `SINCE`, recent-hours, dry-run, and full-inventory behaviors
except for the documented correctness fixes above. Changed-only selection remains
deferred and would require an explicit opt-in. Update `UPGRADE.md` alongside
implemented contract changes, including adapter capabilities, filename changes,
retained generations, history
retention, and any generated schema requirements.

## Delivery sequence and acceptance criteria

Treat each row as a separate reviewable increment. Deferred work is not a release
gate for the earlier increments.

| Increment | Scope | Cheapest adequate acceptance checks |
| --- | --- | --- |
| 1a. Correctness | Resolve the selected source once, leave the unused source untouched, enforce sitemap/index count and byte limits, validate child origins, guard validator cycles, correct date-only cutoff handling, and reject invalid batch sizes. Preserve public API shapes; document stricter validation and changed selection. | Counting providers; URL and Unicode-byte boundary cases; off-origin children; self and multi-file cycles yielding `ValidationError`; date-only and timestamp cutoff boundaries; invalid `SINCE`; zero, malformed, and overlarge batch sizes. |
| 1b. Selection visibility | Non-durable exact plan export with reasons and batch numbers; optional exact attempt output. Planning without a key is explicit. No private store, plan identities, digests, replay, or history API. | Export matches actual request membership for unchanged inputs; missing-key planning makes no requests; excludes credentials; reports undated and date-only selections; preview limitations are documented. |
| 1c. Robots | Opt-in configuration-backed Rails endpoint, independent of publication storage. | GET/HEAD, text content type, short caching, canonical-origin references, injected-line rejection, production-mode staging policy, no content queries, and removal of static route shadowing. |
| Dynamic host wiring | Reuse existing generation entrypoints through host Active Job classes. Keep backend concurrency/scheduling local; add no gem queue layer. | Shared generation checks plus small real GoodJob/Solid Queue integration checks for execution, conflicts, failures, context, and shared-storage visibility. Storage safety also covers direct task invocations. |
| 2a. Streaming and partitions | Replace full-document reformatting, support single-pass entry sources, measure validation/reporting memory, and partition by URL and byte limits. | Single-use enumerators, correct section `lastmod` without a second traversal, deterministic partition boundaries, and representative Places memory/query/runtime measurements. Preserve duplicate rejection; choose a bounded algorithm only with evidence. |
| 2b. Publication | Optional adapter capabilities, immutable children, atomic root activation, metadata, concurrency handling, and retention-aware cleanup. | Legacy adapters still work; unsupported atomic mode fails clearly; interrupted uploads preserve the old generation; cached roots still resolve; format does not rewrite retained children; output ownership survives cleanup and concurrent activation. |
| 2c. Sitemap delivery | Opt-in Rails artifact delivery backed by published metadata. | Allowlisted GET/HEAD, correct headers, 304 before body download, no source queries, filesystem content-type policy, and static-file precedence covered in host tests. |
| 3. Delivery resilience | Batch timeouts and partial-result preservation can land earlier as standalone fixes. Add bounded in-process retries without a ledger or content diff. | Successful early batches survive a later timeout; 200/202 remain distinguishable; retry only failed/unknown batches; verify retry limits, rate limits, sanitized errors, and no exactly-once claims. |
| Decision gate | Durable history requires a separate private store and demonstrated operator need. Inventory diffs and notification reconciliation additionally require meaningful per-URL version inputs. | Written store/access/retention contract and explicit schema/adapter migration scope for history; verified app version inputs and lifecycle rules before approving change detection. No implementation until the relevant prerequisites are met. |

Migrate app infrastructure only after its replacement capability passes focused
host integration tests. Keep Nuntio's static image build database-free. Do not
roll the complete table into one implementation change.

## Verification boundaries

The original investigation ran the existing gem suite successfully: 74 tests and
226 assertions. Its probes established repeated provider evaluation, acceptance
of 50,001 URLs and an off-origin child reference, and partial publication after a
storage failure. Those probes are evidence of current behavior, not passing tests
for this proposal.

Review follow-up probes confirmed that date-only `lastmod` validates but is
excluded under a cutoff, invalid `SINCE` raises rather than falling back, a zero
batch size raises `invalid slice size`, and missing-key dry runs skip selection.
The runtime was the gem workspace's Ruby 4.0.3. Application suites, production
state, historical payloads, and remote delivery were not verified. No requests
were sent to IndexNow. Implementation needs focused failing-before and
passing-after regressions; this document changes no runtime behavior.

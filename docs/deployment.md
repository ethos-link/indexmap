# Choose a deployment path

Source data and HTTP delivery are separate decisions. A database-backed sitemap
can be served as a static file after a scheduled refresh. Static marketing URLs
can be served by a Rails controller. Neither choice generates XML on crawler
requests. Robots policy is independent of both.

| Situation | Generate | Store and serve | Robots |
| --- | --- | --- | --- |
| Static marketing site | Build or release step from an explicit manifest; no database required by the source | Include `public/` artifacts in the deployed image/site | Static file, or Rails endpoint if environment policy varies |
| Database content, one server | Refresh after database preparation and on a host schedule | Persistent filesystem shared by the refresh and web processes; static server or Rails | Static or dynamic policy |
| Database content, multiple containers | Host job on GoodJob/Solid Queue or a release task | Shared persistent filesystem with working locks, or Active Storage with shared backing storage | Dynamic policy is useful for production-mode previews |
| Development or staging | Run the same generation/validation lifecycle with test content | Local filesystem or isolated staging storage | Disallow crawling; do not submit to search engines |

See the [pipeline diagram](architecture.md) for the generation/publication boundary.

## Install and configure

Follow the [Rails installation](../README.md#rails-usage), including
`require: false` and `bin/rails generate indexmap:install`. Edit the configure
block inside `Indexmap::HostConfiguration.apply`, keeping its idempotent wrapper.
Construct storage once there when its settings are fixed:

```ruby
config.base_url = ENV.fetch("INDEXMAP_BASE_URL", "http://localhost:3000")
config.storage = Indexmap::Storage::Filesystem.new(
  path: Rails.public_path, public_url: config.base_url
)
```

Always set `INDEXMAP_BASE_URL` to the actual public origin in deployment. For
private filesystem storage change `path` to `Rails.root.join("storage/sitemaps")`
and explicitly serve it through the Rails controller or web server. That directory
does not become publicly reachable merely because it has a `public_url` setting.
Use separate storage namespaces for development, staging, and production.

### Static sources

For a small, database-free manifest, add to the same configure block:

```ruby
config.format = :single_file
config.entries = -> do
  ["/", "/about", "/pricing"].map do |path|
    Indexmap::Entry.new(loc: "#{config.base_url}#{path}")
  end
end
```

Use an origin without a trailing slash for this example. Supply actual content
modification dates when available; omit `lastmod` when they are unknown. For
larger or grouped manifests use `config.sections` and index mode as in the
[README](../README.md#default-index-mode). Single-file mode fails if it needs to
split; index mode partitions automatically.

The gem does not require a database for a static source. The host Rails boot may
still require services through unrelated initializers. Keep its static build
entrypoint free of database queries, or generate through a plain Ruby script
with `require "indexmap"`, `Indexmap.configure`, and `Indexmap.create`.

### Database-backed sources

Use the [database-backed guide](dynamic-sitemaps.md#configure-generation) for lazy
eligible-record enumeration. Generate after migrations and source transactions
commit. Refresh on a recurring schedule when eligibility depends on time, and
on meaningful publishing events if needed. Hosts own queries, routes, meaningful
dates, authorization context, jobs, and schedules.

For independent static and database outputs, use
[named outputs](../README.md#named-outputs). They do not automatically form a
combined index. Advertise every independent public root in robots.txt and submit
each separately if needed. Generate a deferred output successfully before
advertising it.

## Development verification

```sh
INDEXMAP_BASE_URL=http://localhost:3000 bin/rails indexmap:sitemap:create
INDEXMAP_BASE_URL=http://localhost:3000 bin/rails indexmap:sitemap:validate
bin/rails server
```

From another terminal, fetch the chosen endpoints:

```sh
curl -i http://localhost:3000/sitemap.xml
curl -i http://localhost:3000/robots.txt
```

Expect XML with the configured localhost URLs and robots policy that disallows
crawling. If the root is an index, fetch one referenced child too. Check HEAD
and conditional responses when using controllers. Creation validates before
publishing; the separate validate command checks the stored result. Formatting
is optional for legacy output and unavailable for atomic publications.

## Production static files

For static manifests, generate with the final public origin during a build or
release step, then include every generated root and child in the deployed
artifacts:

```sh
RAILS_ENV=production INDEXMAP_BASE_URL=https://example.com \
  bin/rails indexmap:sitemap:create
RAILS_ENV=production INDEXMAP_BASE_URL=https://example.com \
  bin/rails indexmap:sitemap:validate
```

Do not generate database content during an image build unless database access
and snapshot semantics are deliberate. Use a post-migration release step or job
instead. A release container's generated files must reach the serving instances;
files left on its private filesystem are unavailable to web containers.

Serve `public/` through the deployment's web server/CDN, or explicitly enable
Rails static serving. If the host uses an environment flag, configure its
production environment accordingly:

```ruby
config.public_file_server.enabled = ENV["RAILS_SERVE_STATIC_FILES"] == "1"
```

Set the flag only where Rails should serve these files. A reverse proxy or CDN
can serve them without Rails static serving. Keep stable roots on a short TTL,
and use a long immutable TTL only for atomic generated children. Legacy child
names are overwritten and must not receive immutable caching. Keep previously
referenced children available through the cached-root and rollback period.

A complete image deployed to one server can be enough for a static manifest.
Rolling deployments across different images can expose roots and children from
different releases; use shared storage or deploy all artifacts before switching
the root. Atomic mode protects publication in its configured store, not an
arbitrary deployment system's separate file-copy step.

## Production shared storage and Rails delivery

For refresh jobs across containers, use shared persistent storage. Configure
`config.atomic = true` for revision-checked activation and immutable children.
Choose Filesystem only when locks and rename work across processes, or use the
[Active Storage adapter](../README.md#storage) with a unique artifact filename
index. A shared Active Storage database alone is insufficient if each container
uses a different local disk service.

Mount the root and generated child routes from
[Serve published XML](dynamic-sitemaps.md#serve-published-xml). Store XML outside
`public/` when the controller should own delivery, and remove old static files
that would shadow its routes. The shared controller serves configured roots and
atomic children; legacy index children require deliberate static or host delivery.
A single-file output needs only its root route.

Use one host refresh owner and the host's actual queue adapter; see
[background generation](../README.md#background-generation). Apply the generated
configuration in jobs. `TaskRunner#create` includes key-file handling and
callbacks; `Indexmap.create(:name)` only generates an output. Callbacks can fail
after files are published, so make them safe to repeat and monitor job failures.

Schedule pruning separately for atomic output:

```sh
RAILS_ENV=production RETENTION_HOURS=48 bin/rails indexmap:sitemap:prune
```

Supply the same storage/origin settings as generation. Retain children longer
than cached roots, stale responses, and rollback windows can reference them.
Replace old callbacks that delete files absent from configured section names.

## Static or dynamic robots.txt

Choose one owner for `/robots.txt`:

- **Static:** manage `public/robots.txt` or a web-server file. For a public
  production site, it can contain the following. Deploy a separate disallow file
  for development, staging, and previews.
- **Dynamic:** mount the [robots controller](../README.md#dynamic-robots), remove
  `public/robots.txt`, and configure an explicit environment predicate. It works
  with static or controller-served sitemap XML and does not read sitemap storage.

Public production file:

```text
User-agent: *
Allow: /
Sitemap: https://example.com/sitemap.xml
```

Development, staging, or preview file:

```text
User-agent: *
Disallow: /
```

Dynamic policy inside the configure block:

```ruby
config.robots.indexable = -> { Rails.env.production? && ENV["PUBLIC_INDEXING"] == "1" }
config.robots.groups = [{user_agent: "*", allow: ["/"], disallow: ["/admin/", "/search"]}]
```

Set `PUBLIC_INDEXING=1` only on the intended public deployment. A preview can
run with `RAILS_ENV=production`; that alone must not enable crawling. When the
predicate is false, Indexmap emits disallow-all without sitemap advertisements.
Static robots files ignore this predicate. Keep host-specific exclusions in the
chosen policy. Robots instructions are not access control and do not ensure a
page is removed from an index; protect private routes independently.

## Verify the deployed result

Fetch the actual public root, a referenced child (in index mode), and robots.txt.
Check content, content types, redirects, cache headers, and intended allow/disallow
rules from outside the container. Confirm that job writes are visible from every
serving instance and that a refresh failure retains the old root in atomic mode.
A storage validation pass does not prove HTTP delivery.

Keep search-engine submission separate. Test with
`INDEXNOW_DRY_RUN=1 bin/rails indexmap:index_now:ping` against the correct
environment before live submission; a dry run still needs an IndexNow key.
[Provision the verification key](search-engine-ping.md) at its public URL,
especially when XML lives outside `public/`. Do not submit development or staging
URLs. Google credentials and property setup, IndexNow selection previews, and
attempt reports are covered in the [search-engine guide](search-engine-ping.md).

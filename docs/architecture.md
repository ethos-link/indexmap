# How Indexmap works

The host supplies eligible URLs and content dates. Indexmap generates, validates,
and publishes XML. A web server, CDN, or explicitly mounted Rails controller
serves those artifacts. Crawlers do not trigger generation or query section sources.

```mermaid
flowchart TD
  manifest["Host manifest: static entries or database enumeration"] --> writer
  ruby["Indexmap.create(output)"] --> creator["Creator: selected output"]
  task["Rake create task"] --> runner["TaskRunner#create: default output"]
  job["Host refresh job"] --> runner
  runner --> creator
  creator --> writer["Writer: consume sources once and partition XML"]
  writer --> staging["Temporary disk staging"]
  staging --> validate["Validator: complete graph and disk-backed duplicate checks"]
  validate --> mode{"Publication mode"}
  mode -->|legacy| sequential["Write children, then stable root sequentially"]
  mode -->|atomic| prepare["Prepare children outside the root lock"]
  prepare --> atomic["Check revision and activate root under a short lock"]
  sequential --> storage["Configured storage"]
  atomic --> storage
  creator -->|successful return to TaskRunner| hooks["IndexNow key handling, then after_create callbacks"]
  storage --> static["Static server or CDN"]
  storage --> controller["Opt-in Rails sitemap controller"]
  static --> crawler["Crawler fetches published XML"]
  controller --> crawler
  config["Host robots policy"] --> robots["Static robots.txt or opt-in Rails robots controller"]
  robots --> crawler
  storage --> ping["Separate Google or IndexNow submission"]
```

Generation and validation errors occur before publication. Legacy writes can
leave mixed files if publication itself fails. Atomic mode retains the previous
root until activation succeeds; a competing winner causes
`Indexmap::SupersededPublication`. Built-in adapters clean up ordinary failed
builds; retention covers artifacts left by crashes. Cleanup errors are reported
explicitly. Callbacks and key handling run after publication,
so their failures do not undo it. Neither generation entrypoint submits to search
engines automatically. A host can choose to submit from a callback, but separate
submission makes refresh retries easier to operate.

| Entrypoint | Purpose |
| --- | --- |
| `Indexmap.create(:name)` | Generate, validate, and publish one output; defaults to `:default`. |
| `Indexmap::TaskRunner.new.create` | Generate the default output, handle the IndexNow key, then invoke callbacks. |
| `indexmap:sitemap:create` | Run `TaskRunner#create` and print the writer's recorded counts. |
| `Writer#each_file` / `Writer#write` | Render XML files; callers own validation and publication. `write` collects all files. |
| `indexmap:sitemap:format` | Optionally pretty-print legacy stored files; atomic outputs reject mutation. |
| Sitemap / robots controllers | Serve artifacts or configuration; never generate a sitemap. |

See [domain terms](domain-terms.md), [deployment choices](deployment.md), and the
[storage contract](storage.md).

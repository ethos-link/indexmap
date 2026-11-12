# Domain terms

| Term | Meaning |
| --- | --- |
| Configuration | `Indexmap::Configuration` holds gem settings, sources, outputs, callbacks, and robots policy. |
| Load hook | `ActiveSupport.on_load(:indexmap)` registers host configuration without loading the gem during Rails boot. It runs when Indexmap loads, or immediately if already loaded. |
| Output | One independently generated target with a stable root filename. The default output is usually a sitemap index plus section children. Named outputs share storage and are not linked into that index; advertise each public root separately only when you intentionally want multiple roots. |
| Section | A host-defined child sitemap filename and enumerable of page entries inside one index-mode output. Sections always regenerate with that output; they cannot be refreshed on their own. |
| Page entry | `Indexmap::Entry`: the host's `loc` and optional meaningful content `lastmod`. |
| Parsed entry | `Indexmap::Parser::Entry`: `loc`, `lastmod`, and the source sitemap key/URL. Returned by parsing and validation. |
| Partition | A bounded child XML document produced from a section. One section may produce several partitions. |
| Root | The configured `index_filename`: an index of children, or a URL set in single-file mode. |
| Publication | One generated output made visible in storage. Atomic publications have immutable children and a guarded root activation. |
| Generation | The unique identifier used for an atomic build's child keys and retained root archive. |
| Artifact | A stored XML file, including a root, child, or retained root archive. `Indexmap::Artifact` is the writer's in-memory filename/body/content-type value, not Ruby's filesystem `::File`. |
| Storage key | A relative filename, possibly including directories, such as `sitemaps/sitemap.xml`. It is separate from its public HTTP URL. |
| Static source | Explicit routes or manifest entries that can be generated without querying a database. |
| Dynamic source | Host data selected at refresh time, often through a lazy database enumeration. It does not mean generation during HTTP requests. |
| Format | `:index` or `:single_file` selects XML shape. The separate `format` task changes whitespace in legacy artifacts. |
| Robots policy | Crawl instructions served as `/robots.txt`. It is independent of sitemap storage and refresh scheduling. |

Use these terms in host manifests and operational instructions.
`Indexmap::Configuration` owns settings; the native load hook registers host
configuration. `Indexmap::Artifact` is rendered data and `::File` is Ruby's
filesystem class. Former host loaders `IndexmapConfiguration` and
`Indexmap::HostConfiguration` are superseded by the load hook. See
[UPGRADE.md](../UPGRADE.md) for migration.

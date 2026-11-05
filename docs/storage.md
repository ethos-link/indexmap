# Storage contract

All outputs share `config.storage`. Operation instances resolve storage lazily
once; construct a new runner, validator, creator, or pinger for a new storage
context. Collaborators receive the same adapter through `storage:`. Configure
public URLs where crawlers can fetch artifacts, even when the backing objects are private. Built-in persistent
adapters are `Indexmap::Storage::Filesystem` and
`Indexmap::Storage::ActiveStorage`; the latter uses a host-owned model and attachment.
`Storage::Memory` is useful in tests and retains entire bodies in memory.

## Legacy adapters

The six-method contract remains supported without atomic publication:

```ruby
storage.write(filename, body, content_type: "application/xml")
storage.read(filename)                 # XML string; missing keys should raise
storage.exist?(filename)               # boolean
storage.list(prefix: nil, suffix: nil) # sorted relative keys matching both filters
storage.delete(filename)
storage.public_url(filename)           # public URL for this key
```

`prefix` and `suffix` match the whole relative key, not just its basename.
Write/delete return values are not used by the generation pipeline. Custom
adapters must reject traversal outside their storage namespace and accept nested
relative keys. Restrict the configured filesystem directory to sitemap artifacts:
its `list` method restricts traversal to the prefix's literal directory and
leading filename fragment. Calls without a prefix scan the whole visible tree.
Hidden paths and symlinks are excluded; prefixes must be normalized relative
paths without traversal, absolute paths, or redundant separators.

## Streaming and metadata

These optional methods avoid whole-file read/write fallbacks during generation
and validation. Both are mandatory for the sitemap HTTP controller's reads:

```ruby
storage.open(filename) { |io| ... } # readable binary IO, closed after the block
storage.metadata(filename)         # {etag:, bytes:, last_modified:}
storage.write_io(filename, io, content_type: "application/xml")
```

An ETag must change whenever content changes; `bytes` is uncompressed byte length
and `last_modified` is a time. Active Storage also provides `generation` metadata
for active roots. `write_io` reads from the current IO position. Validation and
parsing use `read` when `open` plus `metadata` are unavailable. Generation uses
`write` when `write_io` is unavailable. These fallbacks retain a whole bounded
file in memory.

## Atomic publication and pruning

```ruby
storage.revision(root) # opaque revision token; nil when the root does not exist
storage.publish(staged_storage, files: filenames, root: root, expected: revision)
storage.prune(root: root, before: cutoff_time) # deleted relative paths
```

`files` lists staged children and the root. `staged_storage.open(key)` supplies
validated XML. An atomic adapter must preserve immutable child keys, coordinate
activation against `expected`, and raise `Indexmap::SupersededPublication` on a
revision mismatch. Root replacement must expose a complete publication; preserve
previously published children for cached roots. A failed publish must not activate
a partial root. Built-in adapters clean up ordinary failed builds immediately;
crashes/outages can still leave orphans. `publish` has no required return value.

Atomic mode requires `revision` and `publish`; pruning additionally requires
`prune`. The shared HTTP controller uses the built-in `Publication` ownership and
archive naming contract. Custom atomic storage intended for that controller must
also preserve those archives and expose `open`/metadata. Do not claim controller
compatibility from `publish` alone.

Pruning must coordinate with activation, preserve the current generation and
other outputs, and remove only expired artifacts owned by the selected root.
Archive retirement time controls the retained generation's grace period.

Active Storage rejects stale builds before uploading, checks again before each
upload, and destroys/purges its failed build's new records and blobs outside the
root lock. Activation verifies child existence under that lock. Work already in
flight can be lost to a race; crashes still need retention/unattached cleanup.
`PublicationCleanupError#failures` identifies cleanup artifacts and errors; the
original publication error remains its cause. Preserve object-key diagnostics if
service deletion fails after a blob row has been destroyed.

Filesystem copies and root-archive preparation occur in private destination
staging outside the root lock. Activation uses renames under the lock. Each build
holds its own staging lock; prune skips live builds and reclaims abandoned
staging after the grace period, returning private directory paths too. See
[publication and retention](dynamic-sitemaps.md#atomic-publication-and-storage)
for filesystem semantics, the required unique Active Storage filename index,
attachment cleanup, and retention operations.

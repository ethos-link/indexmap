# Upgrade Guide

Use this guide when upgrading an application that already generates, validates,
or pings sitemaps with `indexmap`.

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
    # Persist body under filename and store content_type when the backend uses it.
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
- `config.storage.public_url(filename)` returns fetchable sitemap URLs.
- `storage.list(prefix: "sitemap", suffix: ".xml")` returns every generated
  sitemap file, including files under directories.
- `indexmap:sitemap:validate` passes against the same storage used by
  production.
- If IndexNow is enabled, the `<key>.txt` verification file is present in the
  configured storage or `config.index_now.key` is set.

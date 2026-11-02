# Search Engine Ping

`indexmap` can submit generated sitemap data to Google Search Console and
IndexNow. These integrations are optional: sitemap generation, formatting, and
validation work without any search-engine credentials.

Available rake tasks:

```bash
bin/rails indexmap:sitemap:validate
bin/rails indexmap:google:ping
bin/rails indexmap:index_now:ping
bin/rails indexmap:index_now:write_key
bin/rails indexmap:ping
```

`indexmap:ping` runs both IndexNow and Google submission. Run
`indexmap:sitemap:create` before pinging so the configured storage contains the
current sitemap files.

The configured `index_filename` is the authoritative sitemap entrypoint.
Google submits that sitemap URL once. IndexNow recursively reads its referenced
child sitemaps and submits their page URLs. Other sitemap-shaped files left in
storage are ignored unless the authoritative sitemap references them.

## Google Search Console

Google submission uses the Search Console Sitemaps API. It submits sitemap URLs
such as `https://example.com/sitemap.xml` to a verified Search Console
property. It does not submit arbitrary page URLs to Google for immediate
indexing.

Current Google API contract:

- API: Search Console Sitemaps API
- Method: `PUT https://www.googleapis.com/webmasters/v3/sites/{siteUrl}/sitemaps/{feedpath}`
- OAuth scope: `https://www.googleapis.com/auth/webmasters`
- Request body: empty
- Success response body: empty

The Google Indexing API is a separate page-level API at
`POST https://indexing.googleapis.com/v3/urlNotifications:publish` with the
`https://www.googleapis.com/auth/indexing` scope. Google documents that API for
JobPosting pages and livestreaming events with `BroadcastEvent` structured data,
not for general sitemap submission. `indexmap` therefore uses the Search Console
Sitemaps API for Google.

### Create The Google Credentials

1. Open or create a Google Cloud project for the site.
2. Enable the Google Search Console API for that project.
3. Create a service account for sitemap submission.
4. Create a JSON key for that service account.
5. Store the downloaded JSON as a secret in the host app. Do not commit it.
6. Copy the JSON key's `client_email`.
7. Open the Search Console property for the site.
8. Go to `Settings` > `Users and permissions`.
9. Add the service account `client_email` as a user with permission to submit
   sitemaps. `Full` user access is sufficient for sitemap submission; `Owner`
   also works but grants broader access.

The Search Console property must match what `indexmap` submits. Domain
properties use `sc-domain:example.com`; URL-prefix properties use the exact URL
prefix shown in Search Console, such as `https://www.example.com/`.

### Configure Indexmap

`config.google.credentials` must return the JSON key contents, not a path to a
file.

Rails credentials example:

```yaml
google:
  sitemap: |
    {
      "type": "service_account",
      "project_id": "example-project",
      "private_key_id": "...",
      "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
      "client_email": "indexmap-sitemap@example-project.iam.gserviceaccount.com",
      "client_id": "...",
      "auth_uri": "https://accounts.google.com/o/oauth2/auth",
      "token_uri": "https://oauth2.googleapis.com/token",
      "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
      "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/indexmap-sitemap%40example-project.iam.gserviceaccount.com"
    }
```

Initializer example:

```ruby
Indexmap.configure do |config|
  config.google.credentials = -> { Rails.application.credentials.dig(:google, :sitemap) }
  config.google.property = -> { "sc-domain:example.com" }
end
```

Environment variable example:

```ruby
Indexmap.configure do |config|
  config.google.credentials = -> { ENV["GOOGLE_SITEMAP_JSON"] }
  config.google.property = -> { ENV.fetch("GOOGLE_SEARCH_CONSOLE_PROPERTY", "sc-domain:example.com") }
end
```

If `config.google.property` is not set, `indexmap` defaults to
`sc-domain:<host>` from `config.base_url`.

Run:

```bash
bin/rails indexmap:sitemap:create
bin/rails indexmap:sitemap:validate
bin/rails indexmap:google:ping
```

A successful ping prints how many sitemap files and URLs were submitted. If the
task says Search Console does not have access, compare the configured property
identifier and the service account `client_email` against the Search Console
property's `Users and permissions` page.

## IndexNow

IndexNow submission sends changed URL lists to the IndexNow endpoint. It is a
separate protocol from Google Search Console submission.

IndexNow requires a key that proves control of the submitted host. `indexmap`
uses a strict key format: 32 lowercase hexadecimal characters. The verification
file must be named `<key>.txt` unless `config.index_now.key_filename` overrides
the filename, and its contents must be exactly the key.

### File-Based Key Provisioning

The simplest flow is to let `indexmap` generate or reuse the key file:

```bash
bin/rails indexmap:index_now:write_key
```

That task:

- reuses an existing valid `<key>.txt` file from the configured storage
- otherwise generates a new 32-character hexadecimal key
- writes `<key>.txt` with the key as the file contents
- makes that key available to `indexmap:index_now:ping`

After deployment, confirm the key file is publicly reachable:

```bash
curl -fsS https://example.com/<key>.txt
```

The response body should be the key only, with no extra text.

Key discovery only searches `config.storage`. For example, when sitemap storage
points at `storage/sitemaps`, a verification file in Rails' `public/` directory
will not be discovered. Use the configuration below for that arrangement.

### Configured Key

If the host app already stores an IndexNow key in credentials or environment
variables, configure it directly:

```ruby
Indexmap.configure do |config|
  config.index_now.key = -> { ENV["INDEXNOW_KEY"] }
end
```

When `config.index_now.key` is set, `indexmap:sitemap:create` also ensures the
matching `<key>.txt` verification file exists in the configured storage. It
leaves an existing valid key file unchanged.

If the verification file uses a non-standard name, configure it explicitly:

```ruby
Indexmap.configure do |config|
  config.index_now.key = -> { ENV["INDEXNOW_KEY"] }
  config.index_now.key_filename = -> { ENV.fetch("INDEXNOW_KEY") + ".txt" }
end
```

If another part of the host app owns the verification file, disable automatic
key-file writes:

```ruby
Indexmap.configure do |config|
  config.index_now.key = -> { ENV["INDEXNOW_KEY"] }
  config.index_now.write_key_file = false
end
```

### Rails Public Key File With Separate Sitemap Storage

If Rails serves an existing verification file from `public/` while sitemaps
live in `storage/sitemaps` or another backend, configure the key explicitly and
keep the host app responsible for serving the file:

```ruby
Indexmap.configure do |config|
  config.base_url = -> { "https://www.example.com" }
  config.storage = lambda {
    Indexmap::Storage::Filesystem.new(
      path: Rails.root.join("storage/sitemaps"),
      public_url: config.base_url
    )
  }
  config.index_now.key = -> {
    Rails.public_path.join("0123456789abcdef0123456789abcdef.txt").read.strip
  }
  config.index_now.write_key_file = false
end
```

Replace the example filename with your existing `<key>.txt` filename. For a new
key, generate one with `ruby -rsecurerandom -e 'print SecureRandom.hex(16)'`, then
create `public/<key>.txt` containing exactly that key, without a trailing newline.
Deploy the file with the application.

`write_key_file = false` prevents sitemap generation from writing a second key
file into sitemap storage. It does not change where the pinger searches for a
key, so `config.index_now.key` must also be set.

The pinger builds `keyLocation` using
`config.storage.public_url(config.index_now.key_filename)`. In this example,
that URL is `https://www.example.com/<key>.txt`. Ensure the storage adapter
returns the actual public verification URL; adapters with a different public
origin or path need a matching publicly served file there.

The host app must also serve the sitemap files at their configured public URLs.
A filesystem adapter writes files but does not create Rails routes for them.

Before submitting URLs, verify the deployed file and run a dry run in the
production environment:

```bash
curl -fsS https://www.example.com/<key>.txt
RAILS_ENV=production bin/rails indexmap:sitemap:create
RAILS_ENV=production bin/rails indexmap:sitemap:validate
RAILS_ENV=production INDEXNOW_DRY_RUN=1 bin/rails indexmap:index_now:ping
```

The curl response must contain exactly the configured key. A dry run checks
local key loading and sitemap parsing; it does not verify that IndexNow can
fetch the public file. After those checks, run
`RAILS_ENV=production bin/rails indexmap:index_now:ping` to submit the URLs.

### Ping IndexNow

Run:

```bash
bin/rails indexmap:sitemap:create
bin/rails indexmap:sitemap:validate
bin/rails indexmap:index_now:ping
```

For a dry run:

```bash
INDEXNOW_DRY_RUN=1 bin/rails indexmap:index_now:ping
```

By default, `indexmap:index_now:ping` submits all current sitemap URLs. To limit
the submission to recently changed sitemap entries, set one of:

```bash
SINCE=2026-04-18T10:30:00Z bin/rails indexmap:index_now:ping
INDEXNOW_RECENT_HOURS=24 bin/rails indexmap:index_now:ping
```

If the task says the key is missing, either configure `config.index_now.key` or
run `indexmap:index_now:write_key` and deploy the generated key file. If a key
file already exists in `public/`, check whether `config.storage` points at a
different directory; use the separate-storage example above in that case. If the
remote endpoint returns `403`, verify that the public key file URL returns the
same key that `indexmap` is submitting.

## References

- [Google Search Console Sitemaps API](https://developers.google.com/webmaster-tools/v1/sitemaps/submit)
- [Google Search Console API reference](https://developers.google.com/webmaster-tools/v1/api_reference_index)
- [Google Indexing API urlNotifications reference](https://developers.google.com/search/apis/indexing-api/v3/reference/indexing/rest/v3/urlNotifications/)
- [Google Indexing API usage limits](https://developers.google.com/search/apis/indexing-api/v3/using-api)
- [Google Cloud service account keys](https://cloud.google.com/iam/docs/keys-create-delete)
- [Search Console users and permissions](https://support.google.com/webmasters/answer/7687615)
- [IndexNow protocol documentation](https://www.indexnow.org/documentation)

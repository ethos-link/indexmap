# Indexmap

Generate sitemap indexes and child sitemaps from explicit Ruby definitions.

For Ruby and Rails developers who keep sitemap inclusion rules in application code. Storage, URL selection, scheduling and serving remain application responsibilities.

[Project and full documentation](https://www.ethos-link.com/opensource/indexmap) · [RubyGems](https://rubygems.org/gems/indexmap) · [Changelog](CHANGELOG.md)

## Requirements

Ruby 4.0 or newer. Active Support 8 is required; Rails integration is optional. Rails tasks and the install generator target Rails 8.

## Installation

```sh
gem install indexmap
```

## Quick start

```ruby
require "indexmap"

Indexmap.configure do |config|
  config.base_url = "https://example.com"
  config.storage = Indexmap::Storage::Filesystem.new(
    path: "public", public_url: config.base_url
  )
  config.sections = [
    Indexmap::Section.new(
      filename: "sitemap-pages.xml",
      entries: [Indexmap::Entry.new(loc: "https://example.com/")]
    )
  ]
end

Indexmap.create
```

Run from your project directory. This writes `public/sitemap.xml` and `public/sitemap-pages.xml`. The first file references the second; the second contains the home-page URL.

See the [full documentation](https://www.ethos-link.com/opensource/indexmap) for configuration, workflows, operational details and limitations.
For existing installations, read [UPGRADE.md](UPGRADE.md).

## Development and releases

Shared tooling uses published [Ethos Gemkit](https://github.com/ethos-link/ethos-gemkit).
Keep the exact Gemfile version and workflow commit pins on the same release.

```sh
bundle install
bundle exec lefthook install
bundle exec rake verify
```

The PostgreSQL integration suite covers Active Storage, GoodJob and Solid Queue:

```sh
BUNDLE_GEMFILE=gemfiles/integration.gemfile bundle install
INDEXMAP_DATABASE_URL=postgresql://postgres@localhost:5432/indexmap_test \
  BUNDLE_GEMFILE=gemfiles/integration.gemfile bundle exec ruby script/integration
```

Use a disposable `indexmap_test` database; the integration suite recreates it.

Release preparation, publication, registry setup and recovery are documented
in the [Gemkit release guide](https://www.ethos-link.com/opensource/ethos-gemkit#releasing-a-gem).

## About Ethos Link

[Ethos Link](https://www.ethos-link.com) is a software company founded by
[Paulo Fidalgo](https://www.fidalgo.pt). We publish these Ruby tools alongside
our business products:

- [Reviato](https://www.reviato.com): private customer feedback and public review analysis.
- [Nuntio](https://www.nuntiohq.com): prepare, review and schedule social posts.
- [EthosPlaces](https://www.ethos.place): find places, opening hours and contact details.

## License

MIT. See [LICENSE.txt](LICENSE.txt).

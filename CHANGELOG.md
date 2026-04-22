# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-04-22

### Added
- Expand `indexmap` beyond XML generation with `Indexmap::Path`, `Indexmap::Parser`, and `Indexmap::Validator` for sitemap inspection and validation.
- Add `Indexmap::Pinger::Google` and `Indexmap::Pinger::IndexNow` so apps can notify search engines without maintaining local sitemap-specific pingers.
- Add IndexNow key-file writing in `public/` as part of the sitemap workflow.
- Add namespaced rake tasks for validation and search engine notification, including `sitemap:google:ping`, `sitemap:index_now:ping`, `sitemap:index_now:write_key`, and `sitemap:ping`.

### Changed
- Extend configuration with `google` and `index_now` settings so Rails apps can declare search engine credentials and IndexNow behavior in the gem config.
- Move more sitemap ownership into the gem so host apps can keep only their app-specific sitemap manifest and validation rules.

## [0.2.1] - 2026-04-21

### Fixed
- Update the release workflow to build the gem and push the built artifact directly.
- Avoid the GitHub Actions failure caused by `rubygems/release-gem` invoking the guarded `rake release` task.

## [0.2.0] - 2026-04-21

### Added
- Add explicit single-file sitemap mode for smaller Rails sites and route-based sitemap setups.

### Changed
- Keep multi-file sitemap indexes as the default while allowing `sitemap.xml` to be emitted as a direct `urlset` when configured.

## [0.1.0] - 2026-04-21

### Added
- Bootstrap the public `indexmap` gem.
- Add the initial Rails integration with entries, sections, configuration, writer, railtie, and sitemap rake tasks.
- Document the installation and basic sitemap generation workflow.

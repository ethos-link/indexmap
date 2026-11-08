# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.12.1] - 2026-11-08


### Documentation

- recommend independent queued deliveries

- focus queue guidance on published URLs

- recommend independent queued deliveries ([#39](https://github.com/ethos-link/indexmap/pull/39))

- make Ethos Link the canonical documentation home

- add canonical documentation and branded social preview ([#40](https://github.com/ethos-link/indexmap/pull/40))

- keep audited technical guidance alongside the code

- keep audited technical guidance alongside the code ([#41](https://github.com/ethos-link/indexmap/pull/41))



## [0.12.0] - 2026-11-08


### Added

- accept explicit changed entries

- accept explicit changed entries ([#37](https://github.com/ethos-link/indexmap/pull/37))




### Changed

- use BASE_URL in generated initializers

- use BASE_URL in generated initializers ([#36](https://github.com/ethos-link/indexmap/pull/36))

- merge main and preserve both upgrade instructions



## [0.11.0] - 2026-11-06


### Changed

- keep checks local and adopt Gemkit 0.3.1

- keep checks local and adopt Gemkit 0.3.1 ([#32](https://github.com/ethos-link/indexmap/pull/32))




### Fixed

- enforce UTF-8 encoding before partitioning

- enforce UTF-8 encoding before partitioning ([#33](https://github.com/ethos-link/indexmap/pull/33))

- defer sitemap configuration through native load hooks

- simplify lazy sitemap configuration ([#34](https://github.com/ethos-link/indexmap/pull/34))



## [0.10.1] - 2026-11-05


### Changed

- remove unused JSON request middleware

- retire the legacy release branch exception

- retire the legacy release branch exception

- adopt Gemkit 0.3.0

- trim IndexNow and adopt Gemkit 0.3.0 ([#30](https://github.com/ethos-link/indexmap/pull/30))




### Fixed

- preserve release lockfile checksums

- preserve release lockfile checksums ([#29](https://github.com/ethos-link/indexmap/pull/29))



## [0.10.0] - 2026-11-04


### Added

- require Ruby 4 and adopt Gemkit

- require Ruby 4 and adopt Gemkit ([#27](https://github.com/ethos-link/indexmap/pull/27))




### Fixed

- push the version tag during preparation

- push the version tag during preparation ([#26](https://github.com/ethos-link/indexmap/pull/26))



## [0.9.0] - 2026-11-04


### Added

- validate and expose public crawler output

- validate and expose public crawler output ([#21](https://github.com/ethos-link/indexmap/pull/21))

- stream and atomically publish dynamic inventories

- stream and atomically publish dynamic inventories ([#23](https://github.com/ethos-link/indexmap/pull/23))




### Changed

- reconcile writer branch with merged sitemap fixes

- synchronize publication branch with resolved writer base




### Documentation

- explain background sitemap generation ([#19](https://github.com/ethos-link/indexmap/pull/19))

- explain public key setup in Rails ([#20](https://github.com/ethos-link/indexmap/pull/20))

- clarify usage limits and implementation status

- clarify retries are disabled by default

- document unreleased APIs and sitemap deployment choices




### Fixed

- consume sitemap section entries once

- consume sitemap section entries once ([#22](https://github.com/ethos-link/indexmap/pull/22))

- separate review preparation from release tagging

- prepare and push releases from main

- install git-cliff before running release tests

- prepare and push releases from main ([#25](https://github.com/ethos-link/indexmap/pull/25))




### fix

- harden publication and Rails task loading

- harden sitemap publication and Rails integration ([#24](https://github.com/ethos-link/indexmap/pull/24))



## [0.8.2] - 2026-07-22


### Fixed

- use authoritative sitemap entrypoint ([#18](https://github.com/ethos-link/indexmap/pull/18))



## [0.8.1] - 2026-07-21


### Added

- add lazy install generator ([#17](https://github.com/ethos-link/indexmap/pull/17))



## [0.8.0] - 2026-07-21


### Added

- harden git commit ([#15](https://github.com/ethos-link/indexmap/pull/15))




### Changed

- lazy load search console dependencies ([#16](https://github.com/ethos-link/indexmap/pull/16))



## [0.7.1] - 2026-05-31


### Documentation

- document google search console credentials




### Fixed

- preserve release changelog history ([#13](https://github.com/ethos-link/indexmap/pull/13))

- improve sitemap create output ([#14](https://github.com/ethos-link/indexmap/pull/14))



## [0.7.0] - 2026-05-08


### Fixed

- avoid rewriting existing IndexNow key files ([#11](https://github.com/ethos-link/indexmap/pull/11))



## [0.6.0] - 2026-05-01


### Added

- add the url count to google ping output ([#9](https://github.com/ethos-link/indexmap/pull/9))

- support named sitemap outputs ([#10](https://github.com/ethos-link/indexmap/pull/10))



## [0.5.0] - 2026-04-24


### Fixed

- namespace rake tasks and harden sitemap validation ([#8](https://github.com/ethos-link/indexmap/pull/8))



## [0.4.2] - 2026-04-23


### Fixed

- harden sitemap pinging and indexnow key handling ([#7](https://github.com/ethos-link/indexmap/pull/7))



## [0.4.1] - 2026-04-22


### Added

- add output to ping tasks ([#6](https://github.com/ethos-link/indexmap/pull/6))



## [0.4.0] - 2026-04-22


### Documentation

- improve the task messages ([#4](https://github.com/ethos-link/indexmap/pull/4))



## [0.3.1] - 2026-04-22


### Fixed

- fix changelog generation ([#2](https://github.com/ethos-link/indexmap/pull/2))

- harden indexmap runtime defaults and test coverage ([#3](https://github.com/ethos-link/indexmap/pull/3))



## [0.3.0] - 2026-04-22


### Added

- expand indexmap with sitemap parsing, validation, and search engine pinging



## [0.2.1] - 2026-04-21


### Fixed

- publish built gem in release workflow



## [0.2.0] - 2026-04-21


### Added

- add single-file sitemap mode



## [0.1.0] - 2026-04-21


### Added

- bootstrap indexmap gem




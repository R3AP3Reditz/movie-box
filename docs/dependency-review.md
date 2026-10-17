# Preliminary dependency-license review

Reviewed September 28, 2026. This is a recorded technical inventory, not legal approval or a complete redistribution audit. The project's custom no-advertising/no-selling terms apply only to code its copyright holders can license; independently licensed dependencies retain their own rights.

## Python API

The four pinned runtime requirements were resolved in an isolated Python 3.12 environment. The following 15 runtime distributions were reached through their active dependency metadata, excluding optional extras and development tools. Each distribution contained at least one license-named file. License labels below come from package metadata or classifiers, not a line-by-line legal review.

| Distribution | Resolved version | Declared license |
| --- | --- | --- |
| annotated-types | 0.8.0 | MIT |
| anyio | 4.15.1 | MIT |
| certifi | 2026.7.22 | MPL-2.0 |
| click | 8.5.0 | BSD-3-Clause |
| fastapi | 0.115.12 | MIT classifier |
| h11 | 0.16.0 | MIT |
| httpcore | 1.0.9 | BSD-3-Clause |
| httpx | 0.28.1 | BSD-3-Clause |
| idna | 3.20 | BSD-3-Clause |
| pydantic | 2.11.3 | MIT |
| pydantic-core | 2.33.1 | MIT |
| starlette | 0.46.2 | BSD-3-Clause |
| typing-extensions | 4.16.0 | PSF-2.0 |
| typing-inspection | 0.4.4 | MIT |
| uvicorn | 0.34.2 | BSD-3-Clause |

Transitive versions are not locked by `scraper/requirements.txt`; another build can resolve differently. Capture the actual release environment and its notices. In particular, review certifi's MPL-2.0 component obligations and any applicable source-availability requirements rather than treating all Python dependencies as MIT. No conclusion that the whole application must use MPL is implied.

## Direct Flutter packages

All six direct hosted runtime packages were downloaded from their version-specific pub.dev archive URLs. Each archive's SHA-256 matched `movie_box_app/pubspec.lock`. Its top-level license text was inspected for standard MIT or three-clause BSD terms; archives were not extracted to the checkout and package code was not executed.

| Package | Locked version | License text |
| --- | --- | --- |
| cached_network_image | 4.0.2 | MIT |
| cupertino_icons | 1.0.9 | MIT |
| http | 1.6.0 | BSD-3-Clause |
| path_provider | 2.1.6 | BSD-3-Clause |
| shared_preferences | 2.5.5 | BSD-3-Clause |
| video_player | 2.14.0 | BSD-3-Clause |

The lockfile contains **100 package entries**, including SDK, transitive, and development entries. The initial archive inspection covered the six direct hosted runtime packages. A hash match proves correspondence with the existing lockfile, not package safety or ownership.

## Resolved Dart package notice check

After installing official Flutter 3.47.5 stable (Dart 3.13.4), `flutter pub get --enforce-lockfile` succeeded without changing the lockfile. The resulting package configuration contained **95 hosted packages**, including direct, transitive, development, and other-platform packages. Every hosted package had a top-level `LICENSE` file. Automated text-pattern checks found:

| License text pattern | Package count |
| --- | --- |
| BSD-3-Clause | 75 |
| MIT | 10 |
| Apache-2.0 | 5 |
| BSD-2-Clause | 5 |

The five BSD-2-Clause files belong to `sqflite` 2.4.4, `sqflite_android` 2.4.4, `sqflite_common` 2.5.13, `sqflite_darwin` 2.4.4, and `sqflite_platform_interface` 2.4.2. Their explicit license headings and two redistribution clauses were checked after the initial pattern scan flagged them for review. Apache-2.0 text appeared in `clock`, `fake_async`, `material_color_utilities`, `mockito`, and `rxdart`.

This establishes notice-file presence and recognizable license text, not a complete per-file, nested/vendored-code, patent, compatibility, or shipped-artifact audit. The five SDK entries, native libraries, fonts, artwork, and container contents are outside this hosted-package check. Not all 95 packages ship in the Android app.

## Linux additions

Linux support adds `video_player_media_kit` 2.0.0 and `media_kit_libs_linux` 1.2.1, plus their resolved transitive dependencies. The historical counts above predate this addition. Linux playback also dynamically uses the system libmpv and its codec libraries; the Linux plugin builds mimalloc. Inventory their actual licenses and applicable source/redistribution obligations before distributing Linux binaries. The Dart package notices alone do not cover all native-library obligations, and this addition is not a completed compatibility audit.

## Windows additions

Windows support adds `media_kit_libs_windows_video` 1.0.11 alongside the same `video_player_media_kit` plugin, and `background_downloader` runs its pure-Dart desktop implementation rather than the Android foreground service. The historical counts above predate this addition. The Windows media-kit package redistributes a prebuilt libmpv and its codec libraries as native binaries, so the Dart notices in the generated registry do not cover the shipped libraries; inventory their licenses and source/redistribution obligations before distributing Windows binaries. This addition is not a completed compatibility audit.

## Still required before distribution

- Inventory the actual release build's Flutter SDK, transitive Dart packages, native Android artifacts, fonts, and artwork; inspect their licenses and preserve required notices.
- Open **Settings → Credits and licenses → Dependency licenses** on the installed app and verify the generated registry includes the shipped packages. Adding that screen alone does not prove completeness.
- Review the exact Python container's interpreter, operating-system packages, resolved distributions, and notice/source obligations. The container build and smoke tests passed, but they do not establish a complete container-license audit.
- Review the independent downloader's Requests dependency if distributing a runnable downloader environment; it is not in the API requirements.
- Confirm compatibility with the custom project license with qualified legal counsel and verify contribution/asset ownership. Do not relicense dependency code under the custom restrictions.

See [credits](../CREDITS.md), [licensing](licensing.md), and the [release checklist](releasing.md).

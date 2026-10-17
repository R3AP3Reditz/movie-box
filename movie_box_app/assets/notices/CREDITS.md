# Credits and third-party notices

## Project creator

**Movie Box by [R3AP3R Editz](https://github.com/iotserver24)**

Repository: https://github.com/iotserver24/movie-box

Optional donations: https://ai.xibebase.in

Redistributed applications, forks, and public deployments must preserve the creator credit and notices required by [LICENSE](LICENSE). Contributors retain credit and copyright for their own work; the Git history records contributions, but is not a substitute for a provenance review.

## Third-party software

Movie Box depends on independently maintained software. These components retain their own licenses; the project's custom license does not replace or restrict the rights granted by their licenses.

| Area | Direct runtime components |
| --- | --- |
| Application framework | Flutter and Dart |
| Flutter packages | `cupertino_icons`, `http`, `shared_preferences`, `path_provider`, `video_player`, `cached_network_image` |
| Desktop playback | `video_player_media_kit`, `media_kit_libs_linux`, `media_kit_libs_windows_video`, transitive `media_kit` / `media_kit_video`, and platform MPV (system libmpv on Linux, bundled libmpv on Windows) |
| Python API | FastAPI, HTTPX, Pydantic, Uvicorn |
| Standalone experimental downloader | Requests (separate from the API requirements) |
| Packaging | Python container image and its operating-system packages; Android build tooling |

Development tools include `pytest`, `flutter_test`, `flutter_lints`, and `mockito`. Transitive dependencies are also relevant. Consult `movie_box_app/pubspec.yaml`, `movie_box_app/pubspec.lock`, and `scraper/requirements*.txt`, then inspect the actual resolved packages and their license files when building a release.

The [dependency review](docs/dependency-review.md) records a preliminary check of resolved Python runtime metadata and direct Flutter package archives. This list is an acknowledgment, **not a complete license inventory or a completed compatibility audit**. Before distribution, collect required dependency notices, check redistribution conditions, and make them accessible with the build. Flutter's package license registry can help with app notices, but maintainers must verify what is actually included and displayed. See the [release checklist](docs/releasing.md).

## External services and media

MovieBox and upstream media providers are independent third parties. Their names, logos, catalog metadata, artwork, films, streams, and subtitles are not claimed as original project property. This repository's license grants no rights to them and does not imply an affiliation or endorsement. Confirm permissions for every non-code asset you redistribute.

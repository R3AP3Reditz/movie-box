# Architecture

## Components

- **`movie_box_app/`** is the Flutter Android and Linux client. `api.dart` calls the scraper API, `model.dart` parses response models, `screens.dart` contains the main screens, `player.dart` handles playback, and `library.dart` stores preferences, watch history, bookmarks, and download state.
- **`movie_box_app/lib/downloads.dart`** coordinates the persistent download queue as part of `library.dart`. `download_backend.dart` connects it to `background_downloader` platform workers and Android progress notifications. Transfers are not tied to an individual Flutter screen's lifetime.
- **`scraper/app.py`** exposes FastAPI endpoints and optional bearer-token validation. `models.py` defines response schemas, and `provider.py` adapts upstream catalog and playback services to that API.
- **`movie_box_app/lib/notices.dart`** displays creator credit, the bundled project license and acknowledgments, and Flutter's dependency-license page. `scripts/sync_notices.py` synchronizes the app assets from the canonical root notices; `--check` detects drift without writing.
- **`compose.yaml` and `scraper/Dockerfile`** package the Python service. The container runs as a non-root numeric user and publishes port 8000 to the host's loopback interface by default.
- **`script.py`** is a separate experimental downloader with a hard-coded title. Neither the Flutter client nor the API imports it as part of normal startup.

## Request flow

```text
Flutter client --> scraper API --> upstream catalog / playback services
Flutter client -----------------> returned artwork, media, and subtitle URLs
```

The API returns metadata, stream URLs, and required request headers. It does not proxy or store the video. Playback and downloads contact the returned media hosts from the device. Catalog/detail responses have a short in-memory cache; playback and caption links are fetched fresh.

The API has no database or user-account system. A deployment may require a shared bearer token on `/v1/` requests. Its health and API-documentation endpoints remain unauthenticated. The client stores local state in shared preferences. Android downloads use its application documents directory; Linux and Windows downloads use application-support storage. Linux playback is provided by `video_player_media_kit` and libmpv; Windows playback uses the same plugin with `media_kit_libs_windows_video`; Android retains `video_player_android`. Linux and Windows transfers run in-process and stop when the app exits. See [Linux setup](linux.md) and [Windows setup](windows.md).

## Boundaries and limitations

- Provider parsing and upstream compatibility belong in `provider.py`; keep app-facing response contracts stable when fixing upstream changes.
- Signed stream links can expire. Pause/resume depends on server support, and recovery needs an available link; successful recovery is not guaranteed.
- The Android foreground download service requires notification permission with the current plugin. Start, resume, and retry are blocked when permission is denied, with guidance to enable MovieBox notifications in Android Settings.
- The client validates the exact response length before enqueueing a download. Sources whose length remains unknown are rejected with guidance to choose another quality.
- In v1.0.4 (build 5), Android downloads continue in the background with progress notifications. A persistent queue in Downloads exposes pause, resume, cancel, and retry controls.
- Background execution is not unconditional: Android force-stop and battery restrictions can interrupt downloads. Reopen the app to recover its queue and resume or retry interrupted items.
- Upstream season-level information may not describe every episode's exact quality or title.
- An available stream listing does not grant access rights or bypass provider restrictions.
- Shared bearer-token authentication is not a multi-user authorization, rate-limiting, or billing system. Treat the service as a private deployment unless additional protections are implemented and reviewed.

See [API documentation](../scraper/README.md), [privacy](privacy.md), and [security](../SECURITY.md) for operational details.

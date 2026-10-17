# MovieBox Android and Linux app

For native Linux builds, per-user installation, desktop playback, and download limitations, see the [Linux guide](../docs/linux.md).

Flutter client for the scraper API in `../scraper`. The app does not scrape MovieBox directly and contains no ads or account requirement.

## Run

Start the scraper from the repository root (the parent of `movie_box_app/`). On first setup, copy `.env.example` to `.env` and configure it as described in the [setup guide](../docs/setup.md):

```sh
docker compose up -d --build
```

Then, from the repository root, run on an Android emulator or device with a Flutter SDK whose Dart version satisfies `^3.13.1`:

```sh
cd movie_box_app
flutter pub get
flutter run
```

The default API address is `https://movie-box.n92dev.us.kg`. Settings can override it for another deployment, including `http://10.0.2.2:8000` for a locally running scraper on the standard Android emulator. The address field never displays the saved/default address; leave it blank to keep the current server, or enter a replacement. A successfully saved replacement is hidden again. If the server requires `SCRAPER_API_TOKEN`, enter the token in Settings. Keep any local HTTP deployment on a trusted network or private VPN; use HTTPS for a public hostname.

## Features

- Five tabs in this order: Home, Library (bookmarked titles), Search, Downloads, and Settings. Wide Android TV screens use a navigation rail instead of bottom tabs. Home includes a popular carousel, catalogs, cached artwork, and Continue Watching cards with episode, watched time, and a red progress bar. Search returns results as you type.
- Tapping an ordinary title opens its information page with the complete season and episode list. Continue Watching opens the most recently watched episode directly and resumes its saved position; it shows one card per series or movie. The player loads the complete episode list even when the current episode is downloaded, so another episode can be streamed or played offline if saved.
- On phones, the video sits above download, quality, subtitle, title, and episode controls. On TV-sized screens, playback opens directly into an immersive video player with an on-screen remote panel for previous/next episode, season and episode selection, quality, subtitles, and download. English subtitles are selected automatically when available. Tap to show controls, double-tap the left or right side to seek ten seconds. On a keyboard, use F for phone fullscreen and Escape to exit; when the video has focus, Space or Enter toggles playback and Left/Right seeks ten seconds. On a TV remote, use the D-pad to navigate controls, center to select, Left/Right on the video to seek, and Back to leave the player. The screen remains awake while the app is open; TV Search has remote-selectable Search and Clear buttons.
- Custom amber film-frame loading animation for Home, catalogs, search, title details, connection checks, download options, and the player. Player status distinguishes opening, buffering, episode changes, quality changes, and subtitles. Reduced-motion accessibility settings keep the status static; hidden tabs and background apps stop animating.
- In v1.0.4 (build 5), Android downloads continue in the background with progress notifications. Choose quality and subtitle language, then manage the persistent queue in **Downloads** with pause, resume, cancel, and retry controls. Android force-stop and battery restrictions can interrupt downloads; reopen MovieBox to recover the queue and resume or retry interrupted items. Allow MovieBox notifications to start, resume, or retry downloads; if denied, enable them in Android Settings. Pause/resume depends on server support and link availability. Downloads require a verified response length; if the source length is unknown, choose another quality. The Downloads tab shows whether a subtitle was saved and uses a frame extracted from each saved episode as its thumbnail.
- Offline playback from Downloads with saved subtitles, automatic Continue Watching progress by title/season/episode, and delete confirmation. Existing downloads receive thumbnails when the app next starts and the saved video is available.

Android's local HTTP access is enabled for a private scraper server. For a remote deployment, use HTTPS. MovieBox may change or restrict streams; the API's `limited`/`vip_locked` state does not bypass those restrictions.

## Checks

```sh
flutter analyze
flutter test
flutter build apk --debug
```

## Credits, privacy, and license

Created by **[R3AP3R Editz](https://github.com/iotserver24)**. Open **Settings → Credits and licenses** for creator attribution, the full custom license and project acknowledgments bundled for offline reading, and Flutter's dependency-license page. The Donate button in Settings and Credits opens the optional support page in an external browser. If no browser is available, it offers a copy-link fallback; Credits also keeps its copy-only action. See the [project README](../README.md), [privacy notes](../docs/privacy.md), and [credits](../CREDITS.md).

Run `python3 scripts/sync_notices.py --check` from the repository root before building. If the canonical root notices changed, run the same command without `--check` and include the updated bundled assets. Formatting, static analysis, and all 14 Flutter tests passed with Flutter 3.47.5 stable (Dart 3.13.4), including notice access and synchronization. This does not replace Android build, signing, or installed-device checks; see the release checklist.

Production builds require externally supplied signing credentials; see [Android signing](../docs/signing.md). Missing release-signing configuration must fail a normal release build. Debug builds do not require production credentials.

The [custom source-available license](../LICENSE) requires proper creator credit and prohibits advertising and selling the software or charging for access, including in derivatives. Dependencies retain their own licenses. [Optional donations](https://ai.xibebase.in) support development without unlocking features.

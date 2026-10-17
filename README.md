# Movie Box

An ad-free Flutter Android, Linux, and Windows client with a self-hostable Python catalog and playback API, created by **[R3AP3R Editz](https://github.com/iotserver24)**.

Browse and search titles, resume watching, save bookmarks, and download media for offline playback where you have permission to do so. The client talks to the scraper API; the API returns metadata and media links rather than proxying video.

> **Source-available, with conditions:** You may use, modify, and share this project under the [custom license](LICENSE). Keep proper credit to R3AP3R Editz, never add ads, and never sell the project or its derivatives or charge for access. Because these restrictions limit reuse, this is not OSI-approved open source. [Licensing details](docs/licensing.md).

**[Donate to support the creator](https://ai.xibebase.in)** — donations are optional and do not unlock features or access. The destination is the creator's XibeCode-branded support page; review its donor-publicity notice before donating. See [donation privacy](docs/privacy.md#donations).

## Features

- Home sections, catalog browsing, search suggestions, and title details.
- Video playback with available quality and subtitle choices.
- Continue Watching with saved episode and playback position.
- A bookmarked-title library and offline playback of saved downloads.
- Android background downloads with progress notifications and a persistent queue in Downloads, with pause, resume, cancel, and retry controls. Allow MovieBox notifications to start, resume, or retry downloads. Pause/resume depends on server support; unknown-length sources require another quality.
- A configurable API address and optional bearer-token authentication.
- A Docker Compose deployment bound to localhost by default.
- Offline creator-credit and project-license screens, plus dependency notices in Settings.

**Current scope:** Android, Linux, and Windows are the checked-in application targets. See the [Linux build and installation guide](docs/linux.md) and the [Windows build and installation guide](docs/windows.md). Desktop transfers require the app to remain running; the Windows build has not been compiled or run by this project's Linux-based checks. In v1.0.4 (build 5), downloads continue in the background; Android force-stop and battery restrictions can still interrupt them. Reopen MovieBox to recover the persistent queue and resume or retry interrupted items in Downloads. Upstream catalog availability, signed links, subtitle availability, and quality restrictions can change; this project does not bypass locked content.

## Quick start

You need Git, Docker with the Compose plugin, and **Flutter 3.47.5 stable (Dart 3.13.4)**, plus the Android development tools. See [setup and troubleshooting](docs/setup.md) for the local Python alternative and device networking.

```sh
git clone https://github.com/iotserver24/movie-box.git
cd movie-box
cp .env.example .env
docker compose up --build -d
curl http://127.0.0.1:8000/health
```

Copy `.env.example` only on first setup so existing configuration is not overwritten. In another terminal, from the repository root:

```sh
cd movie_box_app
flutter pub get
flutter run
```

In the app's **Settings**, change the API address to your own server. For the standard Android emulator, use `http://10.0.2.2:8000`. A physical device needs a reachable private LAN/VPN address and the matching API token. The app currently defaults to `https://movie-box.n92dev.us.kg`; this repository does not guarantee that deployment's availability or privacy practices. Do not enter your own server's token until you have selected your own server address.

Set a strong `SCRAPER_API_TOKEN` before making the API reachable beyond localhost. Prefer a private VPN; use HTTPS for any remote hostname. Never commit `.env` or share tokens in issues.

## Documentation

| Document | Purpose |
| --- | --- |
| [Setup](docs/setup.md) | Docker, local Python, Android, and troubleshooting |
| [Architecture](docs/architecture.md) | Components, data flow, and implementation limits |
| [Scraper API](scraper/README.md) | Endpoints and API behavior |
| [Android client](movie_box_app/README.md) | Playback, downloads, and app checks |
| [Linux desktop](docs/linux.md) | Linux requirements, build, install, and behavior |
| [Windows desktop](docs/windows.md) | Windows requirements, build, install, and behavior |
| [Privacy](docs/privacy.md) | Local storage, network requests, and deployment responsibilities |
| [Licensing](docs/licensing.md) | Credit, no-ads, no-selling, and donation rules |
| [Contributing](CONTRIBUTING.md) | Development workflow and review expectations |
| [Security](SECURITY.md) | Safe deployment and vulnerability reporting |
| [Code of conduct](CODE_OF_CONDUCT.md) | Community expectations |
| [Credits](CREDITS.md) | Creator and third-party acknowledgments |
| [Release checklist](docs/releasing.md) | Checks before public publication or distribution |
| [Android signing](docs/signing.md) | Production credentials, fail-closed release configuration, and artifact checks |
| [Dependency review](docs/dependency-review.md) | Reviewed packages and remaining third-party obligations |
| [Publication review](docs/publication-review.md) | Automated history checks, limits, and outstanding approvals |

## Development checks

With the Python development environment configured as described in [setup](docs/setup.md):

```sh
python -m pytest scraper/tests -q
python -m unittest discover -s scripts/tests -v
python scripts/sync_notices.py --check
```

From `movie_box_app/`:

```sh
flutter analyze
flutter test
flutter build apk --debug
```

These are commands to run locally, not claims that a particular revision has passed them. See [contributing](CONTRIBUTING.md) before opening a pull request. Feature requests and reproducible non-sensitive bugs belong in [GitHub issues](https://github.com/iotserver24/movie-box/issues).

## Project layout

```text
movie_box_app/   Flutter Android, Linux, and Windows app with widget and integration tests
scraper/         FastAPI service, provider adapter, and Python tests
compose.yaml     Local Docker Compose deployment
script.py        Standalone experimental downloader; not needed by the app
docs/           Setup, architecture, privacy, licensing, and release guidance
```

`script.py` contains a hard-coded download example and starts network/download work when executed; it is not the app's entry point or a setup step.

## Credits and license

**Movie Box by R3AP3R Editz** · [GitHub](https://github.com/iotserver24) · [Donate](https://ai.xibebase.in)

Distributed under the [Movie Box Source-Available License 1.0](LICENSE). Forks and redistributed builds must retain the license and prominent creator credit, remain ad-free, and must not be sold or placed behind paid access. See [credits](CREDITS.md) for dependency acknowledgments.

This project is an independent client and is not presented as an official MovieBox service. The software license does not grant rights to any third-party media, branding, catalog data, or subtitles. Use it only for content and services you are authorized to access and in accordance with applicable law and provider terms.

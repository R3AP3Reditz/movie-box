# MovieBox scraper API

A personal, Dockerized API for the public MovieBox catalog. The Android client should call this service rather than parse the site's pages. The existing root `script.py` downloader is independent.

## Start

From the `movie-box` directory, with Docker and the Compose plugin installed (copy `.env.example` only on first setup):

```sh
cp .env.example .env
docker compose up --build -d
curl http://127.0.0.1:8000/health
```

By default the port is bound to localhost only. For an Android device on the same trusted network, set `SCRAPER_BIND` to the host's private network address and `SCRAPER_API_TOKEN` to a strong random value in `.env`, then restart Compose. Send `Authorization: Bearer <token>` with API requests. Use a private VPN rather than exposing this service on the public internet. Interactive OpenAPI documentation is at `/docs`.

## API

- `GET /v1/home`: banner titles and editorial sections. The site's own Hollywood row leads, followed by its Western TV row and the trending row; regional and language rows follow, and the built-in movie and series catalog rows come last because the app mainly covers titles from outside India.
- `GET /v1/collections/movies` and `GET /v1/collections/midnight`: editorial sections for those site tabs. Home also includes anime and TV sections.
- `GET /v1/browse?page=1&kind=movie`: paginated trending titles. `kind=movie` selects the movie tab automatically; `tab=home|movies|midnight` can select a tab explicitly. `kind` may be `movie`, `series`, `short_series`, or `other`. Kind filtering within a tab can still leave some pages sparse.
- `GET /v1/catalog/movies`, `/v1/catalog/series`, or `/v1/catalog/animation`: paginated full catalog with optional `page`, `genre`, `country`, `year`, `language`, and `sort` query parameters. `GET /v1/catalog/series/filters` and `/v1/catalog/animation/filters` expose the site's current filter choices. Movie filter choices are not published in the available page data; the same query parameters still work for movies.
- `GET /v1/rankings`: current chart names and IDs. `GET /v1/rankings/{id}?page=2` returns paginated chart titles.
- `GET /v1/search?q=masters&page=2`: paginated search. Page 1 uses the same server-rendered results as the website, then appends any extra matches from the JSON search. That page includes multi-season series the JSON search leaves out. Later pages use the JSON search. If the JSON search is unavailable, page 1 still returns the website results and later pages return an error. `GET /v1/search/suggestions?q=masters` and `GET /v1/search/popular` supply autocomplete and popular terms.
- `GET /v1/titles/{detail_path}`: title, cast, available seasons, and alternative audio/dub title paths.
- `GET /v1/titles/{detail_path}/episodes?season=1`: episode numbers. The provider reports season-level counts and qualities, not reliable per-episode titles or quality availability.
- `GET /v1/titles/{detail_path}/recommendations?page=1`: related titles.
- `GET /v1/titles/{detail_path}/playback?season=1&episode=1`: current MP4/DASH/HLS variants and request headers. Movies use the default season/episode `0`. Call again when a signed link expires.
- `GET /v1/titles/{detail_path}/captions?stream_id=...&season=1&episode=1`: separate subtitle URLs for a selected playback stream. Match season/episode to the playback request.

Example for a local API with no token configured:

```sh
curl 'http://127.0.0.1:8000/v1/catalog/movies?page=1'
```

When `SCRAPER_API_TOKEN` is set, use an HTTP client configured with the matching bearer token. For title endpoints, use a `detail_path` returned by the catalog or search and only request content you are authorized to access. These routes contact the upstream provider; use `/health` for a local service check without upstream requests.

Catalog and detail responses have a short in-memory cache; playback and caption links are fetched fresh and never cached. `max_resolution` reports the site's current player limit separately from listed stream variants. The scraper does not proxy or store video. Downloads and Continue Watching belong in the Android app; it should refresh links on playback/download retry and persist progress locally.

## Tests

Use Python 3.12 in a virtual environment; see the [setup guide](../docs/setup.md). From the repository root:

```sh
python -m pip install -r scraper/requirements-dev.txt
python -m pytest scraper/tests -q
```

Tests use fixtures and mocked HTTP responses. If a live check is necessary, use only media you are authorized to access and a small byte-range request, not an entire movie. Site behavior can change; update the provider adapter and its fixtures without changing the app-facing API.

## Security and license

`/health`, `/docs`, `/redoc`, and `/openapi.json` are not protected by the API token. The health check does not contact the upstream provider. See [security](../SECURITY.md), [privacy](../docs/privacy.md), and [architecture](../docs/architecture.md) before deploying beyond localhost.

Created by **[R3AP3R Editz](https://github.com/iotserver24)** and distributed under the [custom source-available license](../LICENSE): retain creator credit, never add ads, and never sell the software or charge for access to it or derivatives. Third-party code and media retain their own rights. [Donate optionally](https://ai.xibebase.in).

The Dockerfile includes the project license at `/app/LICENSE` and creator/dependency acknowledgments at `/app/CREDITS.md`. These files do not replace the required dependency-license review before distributing an image.

import json
import re
import threading
import time
from urllib.parse import quote, urlparse

import httpx

from .models import Caption, CatalogFilters, Detail, Dub, Episode, FilterGroup, FilterValue, Home, Page, Playback, Ranking, Season, Section, Stream, Title

BASE_URL = "https://themoviebox.xyz"
API_PATH = "/wefeed-h5api-bff"


class ProviderError(Exception):
    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status


def _search_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def _kind(value: int | None) -> str:
    return {1: "movie", 2: "series", 7: "short_series"}.get(value, "other")


def _title(raw: dict) -> Title:
    cover = raw.get("cover") or {}
    stills = raw.get("stills") or {}
    return Title(
        id=str(raw.get("subjectId") or ""),
        detail_path=raw.get("detailPath") or "",
        kind=_kind(raw.get("subjectType")),
        title=raw.get("title") or "",
        description=raw.get("description") or "",
        release_date=raw.get("releaseDate") or None,
        duration_seconds=raw.get("duration") or None,
        genres=[v.strip() for v in (raw.get("genre") or "").split(",") if v.strip()],
        poster_url=cover.get("url"),
        backdrop_url=stills.get("url"),
        country=raw.get("countryName") or None,
        rating=raw.get("imdbRatingValue") or None,
        has_resource=bool(raw.get("hasResource")),
    )


def _sections(data: dict) -> Home:
    banners = []
    sections = []
    for item in data.get("operatingList") or []:
        if item.get("type") == "BANNER":
            banners.extend(_title(x["subject"]) for x in (item.get("banner") or {}).get("items") or [] if x.get("subject"))
        elif item.get("subjects"):
            sections.append(Section(title=item.get("title") or "", kind=item.get("type") or "", items=[_title(x) for x in item["subjects"]]))
    return Home(banners=banners, sections=sections)


def _number(value):
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def _nuxt_values(html: str) -> list:
    match = re.search(r'<script[^>]*id="__NUXT_DATA__"[^>]*>(.*?)</script>', html, re.S)
    if not match:
        raise ProviderError("Page has no result data")
    try:
        return json.loads(match.group(1))
    except ValueError as exc:
        raise ProviderError("Page result data is invalid") from exc


def _resolve(values: list, index: int, depth: int = 0):
    if depth > 12 or not isinstance(index, int) or index < 0 or index >= len(values):
        return None
    value = values[index]
    if isinstance(value, dict):
        return {key: _resolve(values, ref, depth + 1) for key, ref in value.items()}
    if isinstance(value, list):
        return [_resolve(values, ref, depth + 1) for ref in value if isinstance(ref, int) and ref >= 0]
    return value


def _nuxt_search(html: str) -> tuple[list[dict], dict]:
    values = _nuxt_values(html)
    for value in values:
        if isinstance(value, dict) and "items" in value and "pager" in value:
            items = _resolve(values, value["items"])
            pager = _resolve(values, value["pager"])
            pager = pager if isinstance(pager, dict) else {}
            if items and isinstance(items[0], dict) and "subjectId" in items[0]:
                return items, pager
            if items == []:
                return [], pager
    raise ProviderError("Search result format changed")


class MovieBoxProvider:
    def __init__(self, client: httpx.Client | None = None, cache_seconds: int = 120):
        self.client = client or httpx.Client(base_url=BASE_URL, timeout=20, follow_redirects=True)
        self.cache_seconds = cache_seconds
        self._cache: dict[str, tuple[float, object]] = {}
        self._subjects: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._guest_token_value: str | None = None
        self.headers = {"Referer": f"{BASE_URL}/", "User-Agent": "Mozilla/5.0", "X-Request-Lang": "en"}

    def close(self):
        self.client.close()

    def _request(self, method: str, path: str, *, params=None, body=None, referer=None, extra_headers=None) -> httpx.Response:
        for attempt in range(3):
            try:
                response = self.client.request(method, path, params=params, json=body, headers={**self.headers, **({"Referer": referer} if referer else {}), **(extra_headers or {})})
            except httpx.RequestError as exc:
                if attempt == 2:
                    raise ProviderError("Provider connection failed") from exc
                time.sleep(0.3 * (attempt + 1))
                continue
            if response.status_code in (429, 500, 502, 503, 504) and attempt < 2:
                time.sleep(0.3 * (attempt + 1))
                continue
            if response.status_code == 404:
                raise ProviderError("Title not found", 404)
            if response.status_code >= 400:
                raise ProviderError(f"Provider returned HTTP {response.status_code}")
            return response
        raise ProviderError("Provider unavailable")

    def _data(self, path: str, *, params=None, body=None, referer=None, extra_headers=None) -> dict:
        response = self._request("POST" if body is not None else "GET", API_PATH + path, params=params, body=body, referer=referer, extra_headers=extra_headers)
        try:
            payload = response.json()
        except ValueError as exc:
            raise ProviderError("Provider returned invalid JSON") from exc
        if payload.get("code") != 0:
            raise ProviderError("Provider rejected the request")
        return payload.get("data") or {}

    def _cached(self, key: str, fetch):
        now = time.monotonic()
        with self._lock:
            entry = self._cache.get(key)
            if entry and entry[0] > now:
                return entry[1]
        value = fetch()
        with self._lock:
            self._cache[key] = (time.monotonic() + self.cache_seconds, value)
        return value

    def home(self) -> Home:
        return self._cached("home", lambda: _sections(self._data("/home", params={"host": "themoviebox.xyz"})))

    def collection(self, name: str) -> Home:
        tabs = {"movies": 2, "midnight": 9}
        if name not in tabs:
            raise ProviderError("Collection not found", 404)
        return self._cached(f"collection:{name}", lambda: _sections(self._data("/tab-operating", params={"tabId": tabs[name], "host": "themoviebox.xyz"})))

    def browse(self, page: int = 1, kind: str | None = None, tab: str | None = None) -> Page:
        selected_tab = tab or ("movies" if kind == "movie" else "home")
        tab_id = {"home": None, "movies": 2, "midnight": 9}.get(selected_tab)
        if selected_tab not in ("home", "movies", "midnight"):
            raise ProviderError("Tab not found", 404)
        params = {"page": page, "perPage": 18}
        if tab_id is not None:
            params["tabId"] = tab_id
        data = self._cached(f"browse:{selected_tab}:{page}", lambda: self._data("/subject/trending", params=params))
        items = [_title(x) for x in data.get("subjectList") or []]
        if kind:
            items = [x for x in items if x.kind == kind]
        pager = data.get("pager") or {}
        return Page(items=items, page=page, next_page=_number(pager.get("nextPage")) if pager.get("hasMore") else None, has_more=bool(pager.get("hasMore")))

    def catalog(self, name: str, page: int = 1, *, genre: str | None = None, country: str | None = None, year: str | None = None, language: str | None = None, sort: str | None = None) -> Page:
        channels = {"movies": 1, "series": 2, "animation": 1006}
        if name not in channels:
            raise ProviderError("Catalog not found", 404)
        body = {"channelId": channels[name], "page": page, "perPage": 28, "sort": sort or "ForYou"}
        body.update({key: value for key, value in {"genre": genre, "country": country, "year": year, "classify": language}.items() if value and value != "All"})
        data = self._cached(f"catalog:{json.dumps(body, sort_keys=True)}", lambda: self._data("/subject/filter", body=body))
        pager = data.get("pager") or {}
        return Page(items=[_title(x) for x in data.get("items") or []], page=page, next_page=_number(pager.get("nextPage")) if pager.get("hasMore") else None, has_more=bool(pager.get("hasMore")))

    def catalog_filters(self, name: str) -> CatalogFilters:
        paths = {"series": "/web/tv-series", "animation": "/web/animated-series"}
        if name not in paths:
            raise ProviderError("Filter choices are unavailable for this catalog", 404)

        def load():
            values = _nuxt_values(self._request("GET", paths[name]).text)
            value = next((x for x in values if isinstance(x, dict) and "filterItemsData" in x), None)
            if not value:
                raise ProviderError("Catalog filter format changed")
            data = _resolve(values, value["filterItemsData"])
            groups = (data.get("typeList") or [{}])[0].get("items") or []
            return CatalogFilters(groups=[FilterGroup(key=x.get("filterType") or "", label=x.get("title") or "", values=[FilterValue(id=str(v.get("id") or ""), label=v.get("name") or "") for v in x.get("filterVals") or []]) for x in groups])
        return self._cached(f"filters:{name}", load)

    def _rankings_data(self) -> dict:
        def load():
            values = _nuxt_values(self._request("GET", "/ranking-list").text)
            value = next((x for x in values if isinstance(x, dict) and "rankingList" in x and "currentId" in x), None)
            if not value:
                raise ProviderError("Ranking menu format changed")
            return _resolve(values, value["rankingList"])
        return self._cached("ranking_menu", load)

    def rankings(self) -> list[Ranking]:
        return [Ranking(id=str(x.get("id") or ""), name=x.get("name") or "") for x in self._rankings_data()]

    def ranking(self, ranking_id: str, page: int = 1) -> Page:
        if ranking_id not in {x.id for x in self.rankings()}:
            raise ProviderError("Ranking not found", 404)
        data = self._cached(f"ranking:{ranking_id}:{page}", lambda: self._data("/ranking-list/content", params={"id": ranking_id, "page": page, "perPage": 20}))
        pager = data.get("pager") or {}
        return Page(items=[_title(x) for x in data.get("subjectList") or []], page=page, next_page=_number(pager.get("nextPage")) if pager.get("hasMore") else None, has_more=bool(pager.get("hasMore")))

    def _guest_token(self) -> str:
        with self._lock:
            if self._guest_token_value:
                return self._guest_token_value
            response = self._request("GET", API_PATH + "/subject/trending", params={"page": 1, "perPage": 1})
            header = response.headers.get("x-user")
            try:
                token = json.loads(header).get("token") if header else None
            except (ValueError, AttributeError):
                token = None
            token = token or self.client.cookies.get("token")
            if not token:
                raise ProviderError("Provider did not issue an anonymous search session")
            self._guest_token_value = token
            return token

    def _api_search(self, keyword: str, page: int) -> Page:
        for attempt in range(2):
            try:
                token = self._guest_token()
                data = self._data("/subject/search", body={"keyword": keyword, "page": page, "perPage": 28, "subjectType": 0}, referer=f"{BASE_URL}/newWeb/searchResult?keyword={quote(keyword)}", extra_headers={"Authorization": f"Bearer {token}"})
                pager = data.get("pager") or {}
                for raw in data.get("items") or []:
                    self._remember(raw)
                return Page(items=[_title(x) for x in data.get("items") or []], page=page, next_page=_number(pager.get("nextPage")) if pager.get("hasMore") else None, has_more=bool(pager.get("hasMore")))
            except ProviderError:
                if attempt:
                    raise
                with self._lock:
                    self._guest_token_value = None
                    self.client.cookies.clear()
        raise ProviderError("Search unavailable")

    def _rendered_search(self, keyword: str) -> tuple[list[dict], dict] | None:
        try:
            response = self._request("GET", "/newWeb/searchResult", params={"keyword": keyword})
            return _nuxt_search(response.text)
        except ProviderError:
            return None

    def _website_query(self, keyword: str) -> str:
        # The exact title page often omits the multi-season series. The
        # suggestion that adds "series" ("mr robot series") is the page that
        # includes it. An equal spelling ("Mr. Robot") is the next best page.
        try:
            words = [word for word in self.suggestions(keyword) if word]
        except ProviderError:
            return keyword
        wanted = _search_key(keyword)
        series = next((word for word in words if _search_key(word).startswith(wanted) and "series" in word.casefold()), None)
        exact = next((word for word in words if _search_key(word) == wanted), None)
        return series or exact or keyword

    def search(self, keyword: str, page: int = 1) -> Page:
        def load():
            # The website's first page is server-rendered and includes multi-season
            # series the JSON search omits (for example Mr. Robot). Later pages still
            # come from the JSON search, which is what the site uses to paginate.
            rendered = self._rendered_search(self._website_query(keyword)) if page == 1 else None
            try:
                api_page = self._api_search(keyword, page)
            except ProviderError:
                if not rendered or not rendered[0]:
                    raise
                api_page = None
            if rendered and rendered[0]:
                seen = set()
                merged = []
                for raw in rendered[0]:
                    self._remember(raw)
                    title = _title(raw)
                    if title.id and title.id not in seen:
                        seen.add(title.id)
                        merged.append(title)
                if api_page:
                    for title in api_page.items:
                        if title.id not in seen:
                            seen.add(title.id)
                            merged.append(title)
                    return Page(items=merged, page=1, next_page=api_page.next_page, has_more=api_page.has_more)
                pager = rendered[1]
                has_more = bool(pager.get("hasMore"))
                return Page(items=merged, page=1, next_page=_number(pager.get("nextPage")) if has_more else None, has_more=has_more)
            if api_page:
                return api_page
            raise ProviderError("Search unavailable")
        return self._cached(f"search:{keyword.casefold()}:{page}", load)

    def suggestions(self, keyword: str) -> list[str]:
        data = self._data("/subject/search-suggest", body={"keyword": keyword, "perPage": 10})
        return [x["word"] for x in data.get("items") or [] if x.get("word")]

    def popular_searches(self) -> list[str]:
        data = self._cached("popular_searches", lambda: self._data("/subject/everyone-search"))
        return [x["title"] for x in data.get("everyoneSearch") or [] if x.get("title")]

    def _remember(self, raw: dict):
        path = raw.get("detailPath") or ""
        if path and raw.get("subjectId"):
            with self._lock:
                self._subjects[path] = raw

    def _play_data(self, detail_path: str, subject_id: str, season: int, episode: int) -> dict:
        params = {"se": season, "ep": episode, "detailPath": detail_path, "streamSignType": 1, "supportCodecs[h264]": 1}
        if subject_id:
            params["subjectId"] = subject_id
        return self._data("/subject/play", params=params, referer=f"{BASE_URL}/movies/{detail_path}")

    def _has_streams(self, data: dict) -> bool:
        return any(item.get("url") for item in (data.get("streams") or []) + (data.get("dash") or []) + (data.get("hls") or []))

    def _probe_seasons(self, detail_path: str, subject_id: str) -> list[Season]:
        seasons = []
        for number in range(1, 21):
            opening = self._play_data(detail_path, subject_id, number, 1)
            if not self._has_streams(opening):
                break
            resolutions = sorted({int(item["resolutions"]) for item in (opening.get("streams") or []) if str(item.get("resolutions") or "").isdigit()})
            low = high = 1
            while high < 40:
                nxt = min(high * 2, 40)
                if not self._has_streams(self._play_data(detail_path, subject_id, number, nxt)):
                    low = high
                    high = nxt - 1
                    break
                low = high = nxt
            while low < high:
                mid = (low + high + 1) // 2
                if self._has_streams(self._play_data(detail_path, subject_id, number, mid)):
                    low = mid
                else:
                    high = mid - 1
            seasons.append(Season(number=number, episode_count=low, resolutions=resolutions))
        return seasons

    def detail(self, detail_path: str) -> Detail:
        if not re.fullmatch(r"[a-zA-Z0-9-]{1,160}", detail_path):
            raise ProviderError("Invalid detail path", 422)

        def load():
            try:
                data = self._data("/detail", params={"detailPath": detail_path})
            except ProviderError as exc:
                if exc.status != 404:
                    raise
                with self._lock:
                    subject = self._subjects.get(detail_path)
                if not subject:
                    raise
                title = _title(subject)
                seasons = [] if title.kind == "movie" else self._probe_seasons(detail_path, title.id)
                return Detail(title=title, cast=[], seasons=seasons, dubs=[], trailer_url=None)
            subject = data.get("subject")
            if not subject:
                raise ProviderError("Title not found", 404)
            title = _title(subject)
            seasons = []
            if title.kind != "movie":
                seasons = [Season(number=int(x["se"]), episode_count=int(x["maxEp"]), resolutions=sorted({int(r["resolution"]) for r in x.get("resolutions") or [] if r.get("resolution")})) for x in (data.get("resource") or {}).get("seasons") or [] if int(x.get("se") or 0) > 0 and int(x.get("maxEp") or 0) > 0]
            dubs = [Dub(id=str(x.get("subjectId")), detail_path=x.get("detailPath") or "", language=x.get("lanCode") or "", label=x.get("lanName") or "", original=bool(x.get("original"))) for x in subject.get("dubs") or []]
            trailer = subject.get("trailer") or {}
            address = trailer.get("videoAddress") or {}
            video = address.get("url") if isinstance(address, dict) else None
            return Detail(title=title, cast=[{"name": x.get("name"), "character": x.get("character"), "image_url": x.get("avatarUrl")} for x in data.get("stars") or []], seasons=seasons, dubs=dubs, trailer_url=video)
        return self._cached(f"detail:{detail_path}", load)

    def episodes(self, detail_path: str, season: int) -> list[Episode]:
        detail = self.detail(detail_path)
        selected = next((x for x in detail.seasons if x.number == season), None)
        if not selected:
            raise ProviderError("Season not found", 404)
        return [Episode(season=season, number=ep) for ep in range(1, selected.episode_count + 1)]

    def recommendations(self, detail_path: str, page: int = 1) -> Page:
        title = self.detail(detail_path).title
        data = self._cached(f"rec:{title.id}:{page}", lambda: self._data("/subject/detail-rec", params={"subjectId": title.id, "page": page, "perPage": 12}))
        items = [_title(x) for x in data.get("items") or []]
        return Page(items=items, page=page, next_page=page + 1 if len(items) == 12 else None, has_more=len(items) == 12)

    def playback(self, detail_path: str, season: int = 0, episode: int = 0) -> Playback:
        title = self.detail(detail_path).title
        if title.kind == "movie":
            season, episode = 0, 0
        if title.kind in ("series", "short_series") and (season < 1 or episode < 1):
            raise ProviderError("Series playback requires season and episode", 422)
        title_page = f"{BASE_URL}/movies/{detail_path}"
        data = self._data("/subject/play", params={"subjectId": title.id, "se": season, "ep": episode, "detailPath": detail_path, "streamSignType": 1, "supportCodecs[h264]": 1}, referer=title_page)
        streams = []
        for value in (data.get("streams") or []) + (data.get("dash") or []) + (data.get("hls") or []):
            url = value.get("url")
            if not url:
                continue
            streams.append(Stream(id=str(value.get("id") or ""), format=value.get("format") or "", resolutions=str(value.get("resolutions") or ""), codec=value.get("codecName"), size_bytes=_number(value.get("size")), duration_seconds=_number(value.get("duration")), url=url, request_headers={"Referer": title_page, "Origin": BASE_URL}, vip_locked=bool(value.get("vipLocked"))))
        return Playback(title_id=title.id, season=season, episode=episode, streams=streams, limited=bool(data.get("limited")), vip_locked=bool(data.get("vipLocked")), max_resolution=_number((data.get("playConfig") or {}).get("maxResolution")))

    def captions(self, detail_path: str, stream_id: str, season: int = 0, episode: int = 0) -> list[Caption]:
        playback = self.playback(detail_path, season, episode)
        stream = next((x for x in playback.streams if x.id == stream_id), None)
        if not stream:
            raise ProviderError("Stream not found for this title", 404)
        data = self._data("/subject/caption", params={"format": stream.format, "id": stream_id, "subjectId": playback.title_id, "detailPath": detail_path}, referer=f"{BASE_URL}/movies/{detail_path}")
        return [Caption(language=x.get("lan") or "", label=x.get("lanName") or "", format=urlparse(x.get("url") or "").path.rsplit(".", 1)[-1].lower(), url=x.get("url") or "", size_bytes=_number(x.get("size")), delay_ms=_number(x.get("delay")) or 0, request_headers={"Referer": f"{BASE_URL}/movies/{detail_path}"}) for x in data.get("captions") or [] if x.get("url")]

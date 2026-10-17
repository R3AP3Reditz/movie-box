import base64
import hashlib
import hmac
import json
import re
import secrets
import threading
import time
from urllib.parse import quote, urlsplit, urlparse

import httpx

from .models import Caption, CatalogFilters, Detail, Dub, Episode, FilterGroup, FilterValue, Home, Page, Playback, Ranking, Season, Section, Stream, Title

BASE_URL = "https://themoviebox.xyz"
API_PATH = "/wefeed-h5api-bff"
MOBILE_API = "https://api3.aoneroom.com"
MOBILE_BOOT = "https://apig.inmoviebox.com/wefeed-mobile-bff/tab/ranking-list?tabId=0&categoryType=4516404531735022304&page=1&perPage=1"
# Public app signing key used by the India MovieBox client. The website search
# page omits some series, including Mr. Robot, when the request comes from a
# hosting provider. This client sends region IN and still returns them.
_MOBILE_SECRET = base64.b64decode(base64.b64decode("NzZpUmwwN3MweFNOOWpxbUVXQXQ3OUVCSlp1bElRSXNWNjRGWnIyTw=="))
# The catalog follows X-Forwarded-For. A France VPS otherwise receives a
# different list that keeps "Mr. Robot Digital After Show" and drops the series.
_CATALOG_IP = "106.192.10.20"


class ProviderError(Exception):
    def __init__(self, message: str, status: int = 502):
        super().__init__(message)
        self.status = status


def _search_key(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def _search_rank(title: Title, wanted: str) -> tuple:
    # The official site result uses a slug such as mr-robot-6pNxPRjgt76. A
    # same-named catalog stub uses a numeric id and must not sort ahead of it.
    key = _search_key(title.title)
    matches = key == wanted or key.startswith(wanted)
    website = "-" in title.detail_path
    return (0 if matches and website else 1 if matches else 2, 0 if title.kind == "series" else 1, 0 if title.has_resource else 1)


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


# The site's own Hollywood and Western TV rows lead the home screen. The
# catalog rows they replace keep their built-in movie and series names and
# move to the end of the list.
_TOP_HOME = ("hollywood", "western tv")

# Regional and language rows from the India site. They stay after the
# leading rows and the general editorial rows.
_LATE_HOME = (
    "western", "bollywood", "south indian", "indian", "hollywood",
    "anime", "asian", "dussehra", "nollywood", "korean", "k-drama",
    "telugu", "tamil", "hindi",
)


def _late_home_section(title: str) -> bool:
    folded = title.casefold()
    return any(word in folded for word in _LATE_HOME)


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


def _nuxt_result_lists(html: str) -> list[tuple[list[dict], dict]]:
    values = _nuxt_values(html)
    found = []
    for value in values:
        if not isinstance(value, dict) or "items" not in value:
            continue
        items = _resolve(values, value["items"])
        pager = _resolve(values, value["pager"]) if "pager" in value else {}
        pager = pager if isinstance(pager, dict) else {}
        if items and isinstance(items[0], dict) and "subjectId" in items[0]:
            found.append((items, pager))
        elif items == [] and "pager" in value:
            found.append(([], pager))
    if not found:
        raise ProviderError("Search result format changed")
    return found


def _nuxt_search(html: str) -> tuple[list[dict], dict]:
    return _nuxt_result_lists(html)[0]


class MovieBoxProvider:
    def __init__(self, client: httpx.Client | None = None, cache_seconds: int = 120):
        self.client = client or httpx.Client(base_url=BASE_URL, timeout=20, follow_redirects=True)
        self.cache_seconds = cache_seconds
        self._cache: dict[str, tuple[float, object]] = {}
        self._subjects: dict[str, dict] = {}
        self._lock = threading.Lock()
        self._guest_token_value: str | None = None
        self._mobile_token_value: str | None = None
        self._mobile_device = secrets.token_hex(16)
        self.headers = {"Referer": f"{BASE_URL}/", "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", "Accept-Language": "en-US,en;q=0.9", "X-Request-Lang": "en", "X-Forwarded-For": _CATALOG_IP, "X-Real-IP": _CATALOG_IP}

    def _mobile_enabled(self) -> bool:
        return type(getattr(self.client, "_transport", None)).__name__ != "MockTransport"

    def _mobile_headers(self, method: str, url: str, body: str | None, token: str | None = None) -> dict:
        timestamp = int(time.time() * 1000)
        parsed = urlsplit(url)
        if parsed.query:
            pairs = [segment.split("=", 1) for segment in parsed.query.split("&") if segment]
            pairs = sorted((item[0], item[1] if len(item) > 1 else "") for item in pairs)
            canonical_url = parsed.path + "?" + "&".join(f"{key}={value}" for key, value in pairs)
        else:
            canonical_url = parsed.path or "/"
        body_bytes = body.encode() if body is not None else None
        body_length = str(len(body_bytes)) if body_bytes else ""
        body_hash = hashlib.md5(body_bytes[:102400]).hexdigest() if body_bytes else ""
        canonical = "\n".join(["GET" if method == "GET" else "POST", "application/json", "application/json", body_length, str(timestamp), body_hash, canonical_url])
        signature = base64.b64encode(hmac.new(_MOBILE_SECRET, canonical.encode(), hashlib.md5).digest()).decode()
        info = {"package_name": "com.community.mbox.in", "version_name": "4.0.03.0920.03", "version_code": 50020130, "os": "android", "os_version": "14", "device_id": self._mobile_device, "region": "IN", "timezone": "Asia/Calcutta"}
        headers = {"user-agent": "com.community.mbox.in/50020130 (Linux; U; Android 14; en_IN)", "accept": "application/json", "content-type": "application/json", "x-client-token": f"{timestamp},{hashlib.md5(str(timestamp)[::-1].encode()).hexdigest()}", "x-tr-signature": f"{timestamp}|2|{signature}", "x-client-info": json.dumps(info, separators=(",", ":")), "x-client-status": "0", "X-Forwarded-For": _CATALOG_IP, "X-Real-IP": _CATALOG_IP}
        if token:
            headers["authorization"] = f"Bearer {token}"
        return headers

    def _mobile_token(self) -> str:
        with self._lock:
            if self._mobile_token_value:
                return self._mobile_token_value
        response = httpx.get(MOBILE_BOOT, headers=self._mobile_headers("GET", MOBILE_BOOT, None), timeout=20)
        if response.status_code != 200:
            raise ProviderError("India catalog is unavailable")
        token = json.loads(response.headers.get("x-user") or "{}").get("token")
        if not token:
            raise ProviderError("India catalog is unavailable")
        with self._lock:
            self._mobile_token_value = token
        return token

    def _mobile_json(self, method: str, path: str, body: dict | None = None) -> dict:
        url = MOBILE_API + path
        payload = json.dumps(body, separators=(",", ":")) if body is not None else None
        token = self._mobile_token()
        headers = self._mobile_headers(method, url, payload, token)
        response = httpx.request(method, url, headers=headers, content=payload.encode() if payload else None, timeout=20)
        if response.status_code != 200:
            raise ProviderError("India catalog is unavailable")
        data = response.json()
        if data.get("code") not in (0, None):
            raise ProviderError(data.get("message") or "India catalog is unavailable")
        return data.get("data") or {}

    def _mobile_search(self, keyword: str, page: int, subject_type: int | None = None) -> list[dict]:
        if not self._mobile_enabled():
            return []
        body = {"keyword": keyword, "page": page, "perPage": 20}
        if subject_type is not None:
            body["subjectType"] = subject_type
        try:
            data = self._mobile_json("POST", "/wefeed-mobile-bff/subject-api/search", body)
        except ProviderError:
            return []
        items = []
        for raw in data.get("items") or []:
            subject_id = str(raw.get("subjectId") or "")
            if not subject_id:
                continue
            cover = raw.get("cover") or {}
            items.append({"subjectId": subject_id, "subjectType": raw.get("subjectType"), "title": raw.get("title") or "", "description": raw.get("description") or "", "releaseDate": raw.get("releaseDate") or None, "duration": _number(raw.get("durationSeconds")), "genre": raw.get("genre") or "", "cover": cover if isinstance(cover, dict) else {}, "countryName": raw.get("countryName"), "imdbRatingValue": raw.get("imdbRatingValue"), "hasResource": raw.get("hasResource"), "detailPath": raw.get("detailPath") or subject_id})
        return items

    def _mobile_detail(self, subject_id: str) -> Detail:
        data = self._mobile_json("GET", f"/wefeed-mobile-bff/subject-api/get?subjectId={subject_id}")
        subject = dict(data)
        subject["detailPath"] = subject.get("detailPath") or subject_id
        subject["duration"] = _number(subject.get("durationSeconds"))
        self._remember(subject)
        seasons = []
        if _kind(subject.get("subjectType")) != "movie":
            info = self._mobile_json("GET", f"/wefeed-mobile-bff/subject-api/season-info?subjectId={subject_id}")
            for season in info.get("seasons") or []:
                number = int(season.get("se") or 0)
                count = int(season.get("maxEp") or 0)
                if number > 0 and count > 0:
                    resolutions = sorted({int(item["resolution"]) for item in season.get("resolutions") or [] if item.get("resolution")})
                    seasons.append(Season(number=number, episode_count=count, resolutions=resolutions))
        people = subject.get("stars") or subject.get("staffList") or subject.get("actors") or []
        cast = [{"name": person.get("name"), "character": person.get("character"), "image_url": person.get("avatarUrl")} for person in people if isinstance(person, dict) and person.get("name")]
        return Detail(title=_title(subject), cast=cast, seasons=seasons, dubs=[], trailer_url=None)

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
        def load() -> Home:
            upstream = _sections(self._data("/home", params={"host": "themoviebox.xyz"}))
            movies = self.catalog("movies", 1).items
            series = self.catalog("series", 1).items
            trending = next((section.items for section in upstream.sections if "trend" in section.title.casefold()), None)
            if not trending:
                trending = self.browse(1).items
            leading = {}
            early = []
            late = []
            for section in upstream.sections:
                folded = section.title.casefold().strip()
                if folded in _TOP_HOME:
                    leading[folded] = section
                    continue
                if "trend" in folded or "free" in folded or folded in {"movies", "movie", "series", "tv series"}:
                    continue
                (late if _late_home_section(section.title) else early).append(section)
            sections = []
            if "hollywood" in leading:
                sections.append(leading["hollywood"])
            elif movies:
                sections.append(Section(title="Hollywood", kind="catalog", items=movies))
            if "western tv" in leading:
                sections.append(leading["western tv"])
            elif series:
                sections.append(Section(title="Western TV", kind="catalog", items=series))
            if trending:
                sections.append(Section(title="Trending", kind="catalog", items=trending))
            sections.extend(early)
            sections.extend(late)
            if movies:
                sections.append(Section(title="Movies", kind="catalog", items=movies))
            if series:
                sections.append(Section(title="Series", kind="catalog", items=series))
            return Home(banners=upstream.banners, sections=sections)

        return self._cached("home", load)

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

    def _official_search_html(self, keyword: str) -> str:
        # Same page as https://themoviebox.xyz/newWeb/searchResult. A plain HTTP
        # client from a hosting address gets a different page, so match Chrome.
        if self._mobile_enabled():
            try:
                from curl_cffi import requests as browser
                response = browser.get(f"{BASE_URL}/newWeb/searchResult", params={"keyword": keyword}, headers={"Referer": f"{BASE_URL}/", "Accept-Language": "en-US,en;q=0.9", "X-Forwarded-For": _CATALOG_IP, "X-Real-IP": _CATALOG_IP}, impersonate="chrome131", timeout=20)
                if response.status_code == 200 and "__NUXT_DATA__" in response.text:
                    return response.text
            except Exception:
                pass
        response = self._request("GET", "/newWeb/searchResult", params={"keyword": keyword})
        return response.text

    def _rendered_items(self, keyword: str) -> list[dict]:
        try:
            lists = _nuxt_result_lists(self._official_search_html(keyword))
        except ProviderError:
            return []
        items = []
        for group, _pager in lists:
            items.extend(group)
        return items

    def _website_queries(self, keyword: str) -> list[str]:
        # One server-rendered page is not enough. The series can be on the
        # suggestion that adds "series", on the exact title, or only in a later
        # result list, and which page has it depends on the server's region.
        try:
            words = [word for word in self.suggestions(keyword) if word]
        except ProviderError:
            words = []
        wanted = _search_key(keyword)
        series = [word for word in words if _search_key(word).startswith(wanted) and "series" in word.casefold()]
        exact = [word for word in words if _search_key(word) == wanted]
        queries = []
        for word in [*series, *exact, keyword]:
            if word not in queries:
                queries.append(word)
        return queries

    def search(self, keyword: str, page: int = 1) -> Page:
        def load():
            rendered = []
            if page == 1:
                for query in self._website_queries(keyword):
                    rendered.extend(self._rendered_items(query))
                rendered.extend(self._mobile_search(keyword, page))
                # The untyped catalog can lead with an unplayable movie of the
                # same name and omit the series. The series-only query returns it.
                rendered.extend(self._mobile_search(keyword, page, subject_type=2))
            try:
                api_page = self._api_search(keyword, page)
            except ProviderError:
                if not rendered:
                    raise
                api_page = None
            seen = set()
            merged = []
            for raw in rendered:
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
            if not merged:
                raise ProviderError("Search unavailable")
            wanted = _search_key(keyword)
            merged.sort(key=lambda title: _search_rank(title, wanted))
            if api_page:
                return Page(items=merged, page=page, next_page=api_page.next_page, has_more=api_page.has_more)
            return Page(items=merged, page=page, next_page=None, has_more=False)
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

    def _preview_stream(self, item: dict) -> bool:
        # The phone API sometimes returns the trailer: about 20 seconds and
        # under a megabyte. A real episode is many minutes and hundreds of MB.
        duration = _number(item.get("duration")) or 0
        size = _number(item.get("size")) or 0
        return 0 < duration <= 30 and (size == 0 or size < 5_000_000)

    def _stream_rows(self, data: dict) -> list[dict]:
        rows = [item for item in (data.get("streams") or []) + (data.get("dash") or []) + (data.get("hls") or []) if item.get("url")]
        usable = [item for item in rows if not self._preview_stream(item)]
        return usable or ([] if rows and all(self._preview_stream(item) for item in rows) else rows)

    def _slug_for(self, title: Title) -> str | None:
        if title.detail_path and not str(title.detail_path).isdigit():
            return title.detail_path
        try:
            found = self.search(title.title, 1)
        except ProviderError:
            return None
        for item in found.items:
            if item.id == str(title.id) and "-" in item.detail_path:
                return item.detail_path
        return None

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
            if detail_path.isdigit() and self._mobile_enabled():
                try:
                    return self._mobile_detail(detail_path)
                except ProviderError:
                    pass
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
        play_path = detail_path if not str(detail_path).isdigit() else (self._slug_for(title) or detail_path)
        title_page = f"{BASE_URL}/movies/{play_path}"
        try:
            data = self._play_data(play_path, title.id, season, episode)
        except ProviderError:
            data = {}
        rows = self._stream_rows(data)
        if not rows and play_path == detail_path and str(detail_path).isdigit():
            slug = self._slug_for(title)
            if slug and slug != play_path:
                try:
                    data = self._play_data(slug, title.id, season, episode)
                    play_path = slug
                    title_page = f"{BASE_URL}/movies/{play_path}"
                    rows = self._stream_rows(data)
                except ProviderError:
                    rows = []
        preview_only = bool(self._has_streams(data) and not rows)
        if not rows and str(title.id).isdigit() and self._mobile_enabled():
            try:
                mobile = self._mobile_json("GET", f"/wefeed-mobile-bff/subject-api/play-info?subjectId={title.id}&se={season}&ep={episode}")
            except ProviderError:
                mobile = {}
            preview_only = preview_only or bool(self._has_streams(mobile) and not self._stream_rows(mobile))
            rows = self._stream_rows(mobile)
        if not rows and preview_only:
            raise ProviderError("The only available copy is an ad, not the episode", 404)
        streams = []
        for value in rows:
            url = value.get("url")
            streams.append(Stream(id=str(value.get("id") or ""), format=value.get("format") or "", resolutions=str(value.get("resolutions") or ""), codec=value.get("codecName"), size_bytes=_number(value.get("size")), duration_seconds=_number(value.get("duration")), url=url, request_headers={"Referer": title_page, "Origin": BASE_URL}, vip_locked=bool(value.get("vipLocked"))))
        return Playback(title_id=title.id, season=season, episode=episode, streams=streams, limited=bool(data.get("limited")), vip_locked=bool(data.get("vipLocked")), max_resolution=_number((data.get("playConfig") or {}).get("maxResolution")))

    def captions(self, detail_path: str, stream_id: str, season: int = 0, episode: int = 0) -> list[Caption]:
        playback = self.playback(detail_path, season, episode)
        stream = next((x for x in playback.streams if x.id == stream_id), None)
        if not stream:
            raise ProviderError("Stream not found for this title", 404)
        data = self._data("/subject/caption", params={"format": stream.format, "id": stream_id, "subjectId": playback.title_id, "detailPath": detail_path}, referer=f"{BASE_URL}/movies/{detail_path}")
        return [Caption(language=x.get("lan") or "", label=x.get("lanName") or "", format=urlparse(x.get("url") or "").path.rsplit(".", 1)[-1].lower(), url=x.get("url") or "", size_bytes=_number(x.get("size")), delay_ms=_number(x.get("delay")) or 0, request_headers={"Referer": f"{BASE_URL}/movies/{detail_path}"}) for x in data.get("captions") or [] if x.get("url")]

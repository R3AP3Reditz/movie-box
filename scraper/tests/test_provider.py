import json

import httpx
import pytest
from fastapi.testclient import TestClient

from scraper.app import app, provider
from scraper.models import Title
from scraper.provider import MovieBoxProvider, ProviderError, _search_key, _search_rank

def test_search_rank_puts_the_official_series_ahead_of_the_same_named_stub():
    wanted = _search_key("Mr. Robot")
    official = Title(id="5136945138450711584", detail_path="mr-robot-6pNxPRjgt76", kind="series", title="Mr. Robot S1-S4", has_resource=True)
    stub = Title(id="4710892163557640360", detail_path="4710892163557640360", kind="movie", title="Mr. Robot", has_resource=False)
    assert _search_rank(official, wanted) < _search_rank(stub, wanted)


SUBJECT = {
    "subjectId": "123", "subjectType": 1, "title": "Example Movie",
    "detailPath": "example-movie-abc", "cover": {"url": "https://example.test/poster.jpg"},
    "genre": "Action, Adventure", "hasResource": True,
}
SERIES = {**SUBJECT, "subjectId": "456", "subjectType": 2, "title": "Example Series", "detailPath": "example-series-xyz"}


def source(responses):
    def handler(request):
        key = (request.method, request.url.path)
        value = responses[key]
        if callable(value):
            value = value(request)
        return httpx.Response(200, json={"code": 0, "data": value})
    return MovieBoxProvider(httpx.Client(base_url="https://themoviebox.xyz", transport=httpx.MockTransport(handler)))


def test_home_and_paginated_browse():
    service = source({
        ("GET", "/wefeed-h5api-bff/home"): {"operatingList": [
            {"type": "BANNER", "banner": {"items": [{"subject": SUBJECT}]}},
            {"type": "SUBJECTS_MOVIE", "title": "Movies", "subjects": [SUBJECT, SERIES]},
        ]},
        ("GET", "/wefeed-h5api-bff/tab-operating"): {"operatingList": [{"type": "SUBJECTS_MOVIE", "title": "Movie picks", "subjects": [SUBJECT]}]},
        ("GET", "/wefeed-h5api-bff/subject/everyone-search"): {"everyoneSearch": [{"title": "Example Movie"}]},
        ("POST", "/wefeed-h5api-bff/subject/search-suggest"): {"items": [{"word": "Example Movie"}]},
        ("GET", "/wefeed-h5api-bff/subject/trending"): {
            "subjectList": [SUBJECT, SERIES], "pager": {"hasMore": True, "nextPage": "2"}
        },
    })
    assert service.home().banners[0].poster_url.endswith("poster.jpg")
    assert [x.kind for x in service.home().sections[0].items] == ["movie", "series"]
    assert service.collection("movies").sections[0].items[0].id == "123"
    with pytest.raises(ProviderError):
        service.collection("unknown")
    result = service.browse(1, "series")
    assert [x.id for x in result.items] == ["456"]
    assert result.next_page == 2
    assert service.browse(1, "movie").items[0].kind == "movie"
    assert service.suggestions("Example") == ["Example Movie"]
    assert service.popular_searches() == ["Example Movie"]


def test_search_server_rendered_data():
    import scraper.provider as module
    values = [None, {"pager": 2, "items": 3}, {"hasMore": 5}, [4], {"subjectId": 6, "subjectType": 7, "title": 8, "detailPath": 9}, True, "123", 1, "Example Movie", "example-movie-abc"]
    html = f'<script type="application/json" id="__NUXT_DATA__">{json.dumps(values)}</script>'
    items, pager = module._nuxt_search(html)
    assert pager.get("hasMore") is True and items[0]["subjectId"] == "123"
    assert module._title(items[0]).title == "Example Movie"
    with pytest.raises(ProviderError):
        module._nuxt_search("no data")


def test_paginated_search_with_anonymous_session():
    calls = []

    def handler(request):
        calls.append(request)
        if request.url.path.endswith("/subject/trending"):
            return httpx.Response(200, headers={"x-user": json.dumps({"token": "guest-token"})}, json={"code": 0, "data": {}})
        assert request.headers["authorization"] == "Bearer guest-token"
        assert json.loads(request.content)["page"] == 2
        return httpx.Response(200, json={"code": 0, "data": {"items": [SUBJECT], "pager": {"hasMore": True, "nextPage": "3"}}})

    service = MovieBoxProvider(httpx.Client(base_url="https://themoviebox.xyz", transport=httpx.MockTransport(handler)))
    result = service.search("Example", 2)
    assert result.items[0].id == "123" and result.next_page == 3
    assert len(calls) == 2
    assert service.search("Example", 2) is result


def test_search_uses_suggestion_spelling_for_the_website_page():
    seen = []

    def handler(request):
        if request.url.path.endswith("/subject/search-suggest"):
            return httpx.Response(200, json={"code": 0, "data": {"items": [{"word": "Mr. Robot"}, {"word": "mr robot series"}]}})
        if request.url.path == "/newWeb/searchResult":
            seen.append(request.url.params["keyword"])
            return httpx.Response(404)
        if request.url.path.endswith("/subject/trending"):
            return httpx.Response(200, headers={"x-user": json.dumps({"token": "guest-token"})}, json={"code": 0, "data": {}})
        if request.url.path.endswith("/subject/search"):
            return httpx.Response(200, json={"code": 0, "data": {"items": [SUBJECT], "pager": {"hasMore": False}}})
        raise AssertionError(request.url)

    service = MovieBoxProvider(httpx.Client(base_url="https://themoviebox.xyz", transport=httpx.MockTransport(handler)))
    assert service.search("mr robot").items[0].title == "Example Movie"
    assert seen == ["mr robot series", "Mr. Robot", "mr robot"]


def test_search_page_includes_series_missing_from_json_search():
    rendered = [None, {"pager": 2, "items": 3}, {"hasMore": 5, "nextPage": 6}, [4], {"subjectId": 7, "subjectType": 8, "title": 9, "detailPath": 10}, True, "2", "456", 2, "Mr. Robot S1-S4", "mr-robot-abc"]
    html = f'<script id="__NUXT_DATA__">{json.dumps(rendered)}</script>'

    def handler(request):
        if request.url.path.endswith("/subject/search-suggest"):
            return httpx.Response(200, json={"code": 0, "data": {"items": []}})
        if request.url.path == "/newWeb/searchResult":
            return httpx.Response(200, text=html)
        if request.url.path.endswith("/subject/trending"):
            return httpx.Response(200, headers={"x-user": json.dumps({"token": "guest-token"})}, json={"code": 0, "data": {}})
        if request.url.path.endswith("/subject/search"):
            return httpx.Response(200, json={"code": 0, "data": {"items": [SUBJECT], "pager": {"hasMore": True, "nextPage": "2"}}})
        raise AssertionError(request.url)

    service = MovieBoxProvider(httpx.Client(base_url="https://themoviebox.xyz", transport=httpx.MockTransport(handler)))
    result = service.search("Mr. Robot")
    assert [item.title for item in result.items] == ["Mr. Robot S1-S4", "Example Movie"]
    assert result.has_more and result.next_page == 2


def test_search_reads_a_later_result_list_when_the_first_omits_the_series():
    rendered = [
        None,
        {"items": 2},
        [3],
        {"subjectId": 4, "subjectType": 5, "title": 6, "detailPath": 7},
        "111",
        2,
        "The Mentalist S1-S7",
        "the-mentalist",
        {"pager": 9, "items": 10},
        {"hasMore": False},
        [11],
        {"subjectId": 12, "subjectType": 13, "title": 14, "detailPath": 15},
        "456",
        2,
        "Mr. Robot S1-S4",
        "mr-robot-abc",
    ]
    html = f'<script id="__NUXT_DATA__">{json.dumps(rendered)}</script>'

    def handler(request):
        if request.url.path.endswith("/subject/search-suggest"):
            return httpx.Response(200, json={"code": 0, "data": {"items": []}})
        if request.url.path == "/newWeb/searchResult":
            return httpx.Response(200, text=html)
        if request.url.path.endswith("/subject/trending"):
            return httpx.Response(200, headers={"x-user": json.dumps({"token": "guest-token"})}, json={"code": 0, "data": {}})
        if request.url.path.endswith("/subject/search"):
            return httpx.Response(200, json={"code": 0, "data": {"items": [], "pager": {"hasMore": False}}})
        raise AssertionError(request.url)

    service = MovieBoxProvider(httpx.Client(base_url="https://themoviebox.xyz", transport=httpx.MockTransport(handler)))
    assert [item.title for item in service.search("Mr. Robot").items] == ["Mr. Robot S1-S4", "The Mentalist S1-S7"]


def test_detail_probes_seasons_when_provider_has_no_detail():
    series = {**SERIES, "detailPath": "mr-robot-abc"}

    def handler(request):
        if request.url.path.endswith("/subject/search-suggest"):
            return httpx.Response(200, json={"code": 0, "data": {"items": []}})
        if request.url.path == "/newWeb/searchResult":
            return httpx.Response(404)
        if request.url.path.endswith("/subject/trending"):
            return httpx.Response(200, headers={"x-user": json.dumps({"token": "guest-token"})}, json={"code": 0, "data": {}})
        if request.url.path.endswith("/subject/search"):
            return httpx.Response(200, json={"code": 0, "data": {"items": [series], "pager": {"hasMore": False}}})
        if request.url.path.endswith("/detail"):
            return httpx.Response(404, json={"code": 404, "message": "subject not found"})
        if request.url.path.endswith("/subject/play"):
            season = int(request.url.params["se"])
            episode = int(request.url.params["ep"])
            streams = [{"id": "video-1", "format": "MP4", "resolutions": "720", "url": "https://cdn.test/ep.mp4"}] if season == 1 and episode <= 10 else []
            return httpx.Response(200, json={"code": 0, "data": {"streams": streams, "dash": [], "hls": []}})
        raise AssertionError(request.url)

    service = MovieBoxProvider(httpx.Client(base_url="https://themoviebox.xyz", transport=httpx.MockTransport(handler)))
    assert service.search("Mr. Robot").items[0].detail_path == "mr-robot-abc"
    detail = service.detail("mr-robot-abc")
    assert [(season.number, season.episode_count) for season in detail.seasons] == [(1, 10)]
    assert detail.seasons[0].resolutions == [720]


def test_search_fallback_when_anonymous_session_is_unavailable():
    values = [None, {"pager": 2, "items": 3}, {"hasMore": 4}, [5], False, {"subjectId": 6, "subjectType": 7, "title": 8, "detailPath": 9}, "123", 1, "Example Movie", "example-movie-abc"]
    html = f'<script id="__NUXT_DATA__">{json.dumps(values)}</script>'
    calls = []

    def handler(request):
        calls.append(request.url.path)
        if request.url.path.endswith("/subject/search-suggest"):
            return httpx.Response(200, json={"code": 0, "data": {"items": []}})
        if request.url.path.endswith("/subject/trending"):
            return httpx.Response(200, json={"code": 0, "data": {}})
        if request.url.path == "/newWeb/searchResult":
            return httpx.Response(200, text=html)
        raise AssertionError(request.url)

    service = MovieBoxProvider(httpx.Client(base_url="https://themoviebox.xyz", transport=httpx.MockTransport(handler)))
    result = service.search("Example")
    assert result.items[0].id == "123" and not result.has_more
    assert calls == ["/wefeed-h5api-bff/subject/search-suggest", "/newWeb/searchResult", "/wefeed-h5api-bff/subject/trending", "/wefeed-h5api-bff/subject/trending"]
    with pytest.raises(ProviderError):
        service.search("Example", 2)


def test_catalog_and_rankings():
    ranking_values = [None, {"rankingList": 2, "currentId": 4}, [3], {"id": 4, "name": 5}, "rank-1", "Top Movies"]
    ranking_html = f'<script id="__NUXT_DATA__" type="application/json">{json.dumps(ranking_values)}</script>'

    def handler(request):
        if request.url.path == "/ranking-list":
            return httpx.Response(200, text=ranking_html)
        if request.url.path.endswith("/subject/filter"):
            body = json.loads(request.content)
            assert body["channelId"] == 1
            assert body["genre"] == "Action"
            return httpx.Response(200, json={"code": 0, "data": {"items": [SUBJECT], "pager": {"hasMore": True, "nextPage": "2"}}})
        if request.url.path.endswith("/ranking-list/content"):
            assert request.url.params["id"] == "rank-1"
            return httpx.Response(200, json={"code": 0, "data": {"subjectList": [SUBJECT], "pager": {"hasMore": False}}})
        raise AssertionError(request.url)

    service = MovieBoxProvider(httpx.Client(base_url="https://themoviebox.xyz", transport=httpx.MockTransport(handler)))
    assert service.catalog("movies", genre="Action").next_page == 2
    assert service.rankings()[0].name == "Top Movies"
    assert service.ranking("rank-1").items[0].id == "123"
    with pytest.raises(ProviderError):
        service.ranking("not-a-rank")
    with pytest.raises(ProviderError):
        service.catalog("invalid")


@pytest.mark.parametrize("params", [{}, {"season": 0, "episode": 0}, {"season": 0, "episode": 1}, {"season": 1, "episode": 0}, {"season": 1, "episode": 1}, {"season": 4, "episode": 9}])
def test_detail_playback_captions_and_api_contract(params):
    calls = []

    def playback(request):
        calls.append("playback")
        assert request.url.params["subjectId"] == "123"
        assert request.url.params["se"] == "0"
        assert request.url.params["ep"] == "0"
        return {"streams": [{"id": "video-1", "format": "MP4", "resolutions": "1080", "url": "https://cdn.test/movie.mp4?sign=secret", "size": "200", "duration": 90}], "dash": [], "hls": [], "playConfig": {"maxResolution": 480}}

    def captions(request):
        calls.append("captions")
        assert request.url.params["id"] == "video-1"
        assert request.url.params["subjectId"] == "123"
        assert request.url.params["format"] == "MP4"
        return {"captions": [{"lan": "en", "lanName": "English", "url": "https://cdn.test/movie.srt?sign=secret", "size": "42", "delay": 0}]}

    service = source({
        ("GET", "/wefeed-h5api-bff/detail"): {"subject": SUBJECT, "stars": [], "resource": {"seasons": [{"se": 0, "maxEp": 0, "resolutions": [{"resolution": 1080}]}]}},
        ("GET", "/wefeed-h5api-bff/subject/play"): playback,
        ("GET", "/wefeed-h5api-bff/subject/caption"): captions,
        ("GET", "/wefeed-h5api-bff/subject/detail-rec"): {"items": [SERIES]},
    })
    app.dependency_overrides[provider] = lambda: service
    try:
        with TestClient(app) as client:
            base = "/v1/titles/example-movie-abc"
            assert client.get("/health").json() == {"status": "ok"}
            detail = client.get(base).json()
            assert detail["title"]["id"] == "123"
            assert detail["seasons"] == []
            assert client.get(base + "/recommendations").json()["items"][0]["kind"] == "series"
            stream = client.get(base + "/playback", params=params).json()
            assert stream["season"] == 0 and stream["episode"] == 0
            assert stream["streams"][0]["format"] == "MP4"
            assert stream["max_resolution"] == 480
            assert client.get(base + "/captions", params={**params, "stream_id": "video-1"}).json()[0]["format"] == "srt"
            assert client.get(base + "/captions", params={**params, "stream_id": "unknown"}).status_code == 404
            assert calls == ["playback", "playback", "captions", "playback"]
            assert client.get(base + "/episodes?season=1").status_code == 404
            assert client.get("/v1/browse?page=0").status_code == 422
    finally:
        app.dependency_overrides.clear()


@pytest.mark.parametrize("subject_type", [1, 2, 7, 0])
def test_detail_only_exposes_positive_episodic_seasons(subject_type):
    service = source({
        ("GET", "/wefeed-h5api-bff/detail"): {
            "subject": {**SERIES, "subjectType": subject_type},
            "resource": {"seasons": [
                {"se": 0, "maxEp": 0},
                {"se": 0, "maxEp": 3},
                {"se": 1, "maxEp": 0},
                {"se": -1, "maxEp": 3},
                {"se": 1, "maxEp": -1},
                {"se": "2", "maxEp": "3", "resolutions": [{"resolution": 1080}]},
            ]},
        },
    })
    detail = service.detail(SERIES["detailPath"])
    if subject_type == 1:
        assert detail.seasons == []
        with pytest.raises(ProviderError) as error:
            service.episodes(SERIES["detailPath"], 2)
        assert error.value.status == 404
    else:
        assert [season.model_dump() for season in detail.seasons] == [{"number": 2, "episode_count": 3, "resolutions": [1080]}]
        assert [(episode.season, episode.number) for episode in service.episodes(SERIES["detailPath"], 2)] == [(2, 1), (2, 2), (2, 3)]


@pytest.mark.parametrize("subject_type", [2, 7])
def test_series_playback_preserves_positive_season_and_episode(subject_type):
    def playback(request):
        assert request.url.params["subjectId"] == "456"
        assert request.url.params["se"] == "2"
        assert request.url.params["ep"] == "3"
        return {"streams": []}

    service = source({
        ("GET", "/wefeed-h5api-bff/detail"): {"subject": {**SERIES, "subjectType": subject_type}},
        ("GET", "/wefeed-h5api-bff/subject/play"): playback,
    })
    result = service.playback(SERIES["detailPath"], 2, 3)
    assert result.season == 2 and result.episode == 3


@pytest.mark.parametrize("subject_type", [2, 7])
@pytest.mark.parametrize("season,episode", [(0, 0), (0, 1), (1, 0), (-1, 1), (1, -1)])
def test_series_playback_rejects_invalid_season_or_episode(subject_type, season, episode):
    service = source({
        ("GET", "/wefeed-h5api-bff/detail"): {"subject": {**SERIES, "subjectType": subject_type}},
    })
    with pytest.raises(ProviderError, match="Series playback requires season and episode") as error:
        service.playback(SERIES["detailPath"], season, episode)
    assert error.value.status == 422
    with pytest.raises(ProviderError, match="Series playback requires season and episode") as error:
        service.captions(SERIES["detailPath"], "video-1", season, episode)
    assert error.value.status == 422

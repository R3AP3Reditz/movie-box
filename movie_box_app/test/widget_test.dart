import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_box_app/api.dart';
import 'package:movie_box_app/library.dart';
import 'package:movie_box_app/main.dart';
import 'package:movie_box_app/model.dart';
import 'package:movie_box_app/player.dart';
import 'package:movie_box_app/screens.dart';

import 'downloads_test.dart' show FakeDownloadBackend;

void main() {
  test('API sends token, search page and episode parameters', () async {
    final seen = <Uri>[];
    final api = MovieApi(
      baseUrl: 'http://example.test:8000/',
      token: 'secret',
      client: MockClient((request) async {
        seen.add(request.url);
        expect(request.headers['Authorization'], 'Bearer secret');
        return http.Response(
          jsonEncode(
            request.url.path.endsWith('search')
                ? {'items': [], 'page': 2, 'next_page': 3, 'has_more': true}
                : {'streams': [], 'limited': false, 'vip_locked': false},
          ),
          200,
        );
      }),
    );
    expect((await api.search('master & universe', 2)).next, 3);
    await api.playback('sample-title', 1, 3);
    expect(seen.first.queryParameters, {'q': 'master & universe', 'page': '2'});
    expect(seen.last.queryParameters, {'season': '1', 'episode': '3'});
  });

  test('Artwork requests a small CDN thumbnail', () {
    expect(
      artworkUrl('https://pbcdnw.aoneroom.com/image/poster.jpg', 420),
      contains('x-oss-process=image%2Fresize%2Cw_420'),
    );
    expect(
      artworkUrl('https://other.example/poster.jpg', 420),
      'https://other.example/poster.jpg',
    );
  });

  test('SRT subtitles parse timestamps and multiline text', () {
    final captions = SrtCaptions(
      '1\n00:00:01,000 --> 00:00:02,500\nHello\nworld\n\n2\n00:00:03,000 --> 00:00:04,000\nNext',
    );
    expect(captions.captions.length, 2);
    expect(captions.captions.first.text, 'Hello\nworld');
    expect(captions.captions.first.end.inMilliseconds, 2500);
  });

  testWidgets('Catalog loads, paginates and opens details', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final library = MovieLibrary(await SharedPreferences.getInstance());
    final title = {
      'id': '1',
      'detail_path': 'example-title',
      'kind': 'movie',
      'title': 'Example Title',
      'has_resource': true,
    };
    final api = MovieApi(
      baseUrl: 'http://example.test',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/catalog/movies')) {
          final page = int.parse(request.url.queryParameters['page']!);
          return http.Response(
            jsonEncode({
              'items': [
                {
                  ...title,
                  'title': page == 1 ? 'Example Title' : 'Second Page',
                },
              ],
              'page': page,
              'next_page': page == 1 ? 2 : null,
              'has_more': page == 1,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'title': title, 'seasons': [], 'dubs': []}),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CatalogScreen(
            api: api,
            library: library,
            name: 'movies',
            label: 'Movies',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Example Title'), findsOneWidget);
    await tester.tap(find.text('Load more'));
    await tester.pumpAndSettle();
    expect(find.text('Second Page'), findsOneWidget);
    await tester.tap(find.text('Example Title'));
    await tester.pumpAndSettle();
    expect(find.text('Title details'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Download video + subtitles'), findsNothing);
  });

  testWidgets('Search waits for results while typing and replaces the query', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final library = MovieLibrary(await SharedPreferences.getInstance());
    final seen = <String>[];
    final api = MovieApi(
      baseUrl: 'http://example.test',
      client: MockClient((request) async {
        if (request.url.path.endsWith('/popular')) {
          return http.Response('[]', 200);
        }
        final query = request.url.queryParameters['q']!;
        seen.add(query);
        return http.Response(
          jsonEncode({
            'items': [
              {
                'id': query,
                'detail_path': 'title-$query',
                'title': '$query result',
                'kind': 'movie',
                'has_resource': true,
              },
            ],
            'page': 1,
            'next_page': null,
            'has_more': false,
          }),
          200,
        );
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchScreen(api: api, library: library),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'master');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('No results found.'), findsNothing);
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(find.text('master result'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'universe');
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(find.text('universe result'), findsOneWidget);
    expect(find.text('master result'), findsNothing);
    expect(seen, ['master', 'universe']);
  });

  testWidgets(
    'Downloads screen offers offline entries and delete confirmation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final library = MovieLibrary(await SharedPreferences.getInstance());
      final title = MovieTitle.fromJson({
        'id': '1',
        'detail_path': 'film',
        'kind': 'movie',
        'title': 'Film',
      });
      await library.addDownload(
        SavedDownload(
          title,
          0,
          0,
          '720',
          '/tmp/not-a-real-video.mp4',
          '/tmp/not-a-real-caption.srt',
        ),
      );
      final api = MovieApi(
        baseUrl: 'http://example.test',
        client: MockClient((_) async => http.Response('{}', 200)),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryScreen(api: api, library: library),
          ),
        ),
      );
      expect(find.text('Downloads'), findsOneWidget);
      expect(find.text('Film'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete download'));
      await tester.pumpAndSettle();
      expect(find.text('Delete download?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(library.downloads, isEmpty);
    },
  );

  testWidgets('Continue Watching groups series and opens its latest episode', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final library = MovieLibrary(await SharedPreferences.getInstance());
    final title = MovieTitle.fromJson({
      'id': '1',
      'detail_path': 'series',
      'kind': 'series',
      'title': 'Series',
    });
    await library.record(WatchEntry(title, 1, 1, 60, 600));
    await library.record(WatchEntry(title, 1, 2, 120, 600));
    final api = MovieApi(
      baseUrl: 'http://example.test',
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: ContinueRow(
              latestWatchEntries(library.history.values),
              library,
              (entry) =>
                  openTitle(context, api, library, entry.title, resume: entry),
            ),
          ),
        ),
      ),
    );
    expect(latestWatchEntries(library.history.values), hasLength(1));
    expect(find.text('S1 E1 · 1 min'), findsNothing);
    await tester.tap(find.text('S1 E2 · 2 min'));
    await tester.pumpAndSettle();
    expect(tester.widget<PlayerScreen>(find.byType(PlayerScreen)).episode, 2);
  });

  testWidgets('Downloaded playback still loads the full episode list', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final library = MovieLibrary(await SharedPreferences.getInstance());
    final title = MovieTitle.fromJson({
      'id': '1',
      'detail_path': 'series',
      'kind': 'series',
      'title': 'Series',
    });
    final saved = SavedDownload(
      title,
      1,
      2,
      '360',
      '/tmp/missing-moviebox.mp4',
      null,
    );
    final api = MovieApi(
      baseUrl: 'http://example.test',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'title': title.toJson(),
            'seasons': [
              {
                'number': 1,
                'episode_count': 5,
                'resolutions': [360],
              },
              {
                'number': 2,
                'episode_count': 3,
                'resolutions': [360],
              },
            ],
            'dubs': [],
          }),
          200,
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          api: api,
          library: library,
          title: title,
          season: 1,
          episode: 2,
          offline: saved,
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.drag(find.byType(ListView).first, const Offset(0, -500));
    await tester.pump();
    expect(find.text('Season 1'), findsOneWidget);
    final selector = find.byKey(const ValueKey('mobile-episode-selector'));
    final dropdown = tester.widget<DropdownButton<(int, int)>>(selector);
    expect(dropdown.value, (1, 2));
    expect(dropdown.items!.map((item) => item.value), [
      (1, 1),
      (1, 2),
      (1, 3),
      (1, 4),
      (1, 5),
    ]);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Season 1 · Episode 2'), findsOneWidget);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    expect(find.text('Episode 5').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Episode 3').hitTestable());
    await tester.pump();
    expect(find.text('Season 1 · Episode 3'), findsOneWidget);
  });

  testWidgets('TV player offers season, episode, and adjacent controls', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final library = MovieLibrary(await SharedPreferences.getInstance());
    final title = MovieTitle.fromJson({
      'id': '1',
      'detail_path': 'series',
      'kind': 'series',
      'title': 'Series',
    });
    final api = MovieApi(
      baseUrl: 'http://example.test',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'title': title.toJson(),
            'seasons': [
              {'number': 1, 'episode_count': 3},
              {'number': 2, 'episode_count': 2},
            ],
            'dubs': [],
          }),
          200,
        ),
      ),
    );
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerScreen(
          api: api,
          library: library,
          title: title,
          season: 1,
          episode: 2,
          offline: SavedDownload(
            title,
            1,
            2,
            '360',
            '/tmp/missing-tv.mp4',
            null,
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('Previous'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('Episode 3'), findsOneWidget);
    expect(find.text('Download video + subtitles'), findsNothing);
    await tester.tap(find.text('Episode 3'));
    await tester.pump();
    expect(find.textContaining('S1 E3'), findsOneWidget);
  });

  testWidgets('Wide TV layout navigates all five destinations', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final library = MovieLibrary(
      await SharedPreferences.getInstance(),
      downloadBackend: FakeDownloadBackend(),
    );
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MovieBoxApp(library: library));
    final transitions = tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .theme!
        .pageTransitionsTheme
        .builders;
    expect(
      (transitions[TargetPlatform.linux] as ZoomPageTransitionsBuilder)
          .allowSnapshotting,
      isFalse,
    );
    expect(
      transitions[TargetPlatform.android].runtimeType,
      const PageTransitionsTheme().builders[TargetPlatform.android].runtimeType,
    );
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    for (final pair in [
      ('Library', 'No bookmarks yet.'),
      ('Search', 'Find a movie or series'),
      ('Downloads', 'Saved on this device'),
      ('Settings', 'API address'),
    ]) {
      await tester.tap(find.text(pair.$1).first);
      await tester.pump();
      expect(find.textContaining(pair.$2), findsWidgets);
      if (pair.$1 == 'Search') {
        await tester.pump();
        expect(find.text('Clear'), findsOneWidget);
        expect(find.byType(TextField), findsOneWidget);
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue,
        );
      }
    }
    await tester.tap(find.text('Home').first);
    await tester.pump();
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  test('Download artwork path persists with the episode', () async {
    final title = MovieTitle.fromJson({
      'id': '1',
      'detail_path': 'series',
      'kind': 'series',
      'title': 'Series',
    });
    final saved = SavedDownload(
      title,
      1,
      2,
      '360',
      '/tmp/video.mp4',
      null,
      thumbnailPath: '/tmp/video.mp4.jpg',
    );
    final restored = SavedDownload.fromJson(saved.toJson());
    expect(restored.thumbnailPath, '/tmp/video.mp4.jpg');
    expect(restored.key, 'series:1:2');
  });

  test('watch progress and downloads persist locally', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final library = MovieLibrary(prefs);
    final title = MovieTitle.fromJson({
      'id': '1',
      'detail_path': 'film',
      'kind': 'movie',
      'title': 'Film',
    });
    await library.toggleBookmark(title);
    expect(MovieLibrary(prefs).bookmarks['film']?.title, 'Film');
    await library.toggleBookmark(title);
    expect(MovieLibrary(prefs).bookmarks, isEmpty);
    await library.record(WatchEntry(title, 0, 0, 90, 200));
    expect(MovieLibrary(prefs).history['film:0:0']!.positionSeconds, 90);
    await library.record(WatchEntry(title, 0, 0, 199, 200));
    expect(MovieLibrary(prefs).history, isEmpty);
  });
}

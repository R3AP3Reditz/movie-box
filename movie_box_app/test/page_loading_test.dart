import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:movie_box_app/api.dart';
import 'package:movie_box_app/desktop.dart';
import 'package:movie_box_app/library.dart';
import 'package:movie_box_app/loading.dart';
import 'package:movie_box_app/main.dart';
import 'package:movie_box_app/screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloads_test.dart' show FakeDownloadBackend;

class _Responses {
  final requests = <http.Request>[];
  final pending = <Completer<http.Response>>[];
  late final client = MockClient((request) {
    if (request.url.path.endsWith('/popular')) {
      return Future.value(http.Response('[]', 200));
    }
    if (request.url.path.endsWith('/recommendations')) {
      return Future.value(http.Response('{"items":[]}', 200));
    }
    requests.add(request);
    final response = Completer<http.Response>();
    pending.add(response);
    return response.future;
  });
  late final api = MovieApi(baseUrl: 'https://example.test', client: client);

  void complete(int index, Object body, {int status = 200}) {
    pending[index].complete(http.Response(jsonEncode(body), status));
  }

  void fail(int index) =>
      complete(index, {'detail': 'Server unavailable'}, status: 503);
}

class _SavingLibrary extends MovieLibrary {
  Completer<void> saved = Completer<void>();
  _SavingLibrary(super.prefs);

  @override
  Future<void> configure(String address, String apiToken) async {
    await saved.future;
    await super.configure(address, apiToken);
  }
}

Map<String, Object> _title(String name) => {
  'id': name,
  'detail_path': name,
  'title': name,
  'kind': 'movie',
  'has_resource': true,
};

Map<String, Object?> _page(String name, {int? next}) => {
  'items': [_title(name)],
  'next_page': next,
};

Map<String, Object> _home(String name) => {
  'sections': [
    {
      'title': 'Latest releases',
      'items': [_title(name)],
    },
  ],
};

Widget _screen(Widget child) => MaterialApp(home: Scaffold(body: child));

Future<void> _flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

void _expectLoader(WidgetTester tester, String label, {bool compact = false}) {
  final finder = find.byWidgetPredicate(
    (widget) => widget is MovieBoxLoader && widget.label == label,
  );
  expect(finder, findsOneWidget);
  expect(tester.widget<MovieBoxLoader>(finder).compact, compact);
  expect(find.byType(CircularProgressIndicator), findsNothing);
}

void main() {
  late MovieLibrary library;
  late _Responses responses;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    library = MovieLibrary(
      await SharedPreferences.getInstance(),
      downloadBackend: FakeDownloadBackend(),
    );
    responses = _Responses();
  });

  tearDown(() {
    responses.api.close();
    library.dispose();
  });

  testWidgets(
    'Home reports initial failure, retry, refresh and refresh failure',
    (tester) async {
      await tester.pumpWidget(
        _screen(HomeScreen(api: responses.api, library: library)),
      );
      _expectLoader(tester, 'Loading your home');
      responses.fail(0);
      await tester.pumpAndSettle();
      expect(find.text('Server unavailable'), findsOneWidget);
      expect(find.byType(MovieBoxLoader), findsNothing);

      await tester.tap(find.text('Try again'));
      await _flush(tester);
      _expectLoader(tester, 'Loading your home');
      expect(find.text('Server unavailable'), findsNothing);
      responses.complete(1, _home('First title'));
      await tester.pumpAndSettle();
      expect(find.text('First title'), findsOneWidget);

      var refresh = tester.widget<RefreshIndicator>(
        find.byType(RefreshIndicator),
      );
      final refreshed = refresh.onRefresh();
      await _flush(tester);
      _expectLoader(tester, 'Loading your home');
      responses.complete(2, _home('Refreshed title'));
      await refreshed;
      await tester.pumpAndSettle();
      expect(find.text('Refreshed title'), findsOneWidget);
      expect(find.text('First title'), findsNothing);

      refresh = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
      final failedRefresh = refresh.onRefresh();
      await _flush(tester);
      _expectLoader(tester, 'Loading your home');
      responses.fail(3);
      await expectLater(failedRefresh, completes);
      await tester.pumpAndSettle();
      expect(find.text('Server unavailable'), findsOneWidget);
      expect(find.byType(MovieBoxLoader), findsNothing);

      await tester.tap(find.text('Try again'));
      await _flush(tester);
      _expectLoader(tester, 'Loading your home');
      responses.complete(4, _home('Recovered title'));
      await tester.pumpAndSettle();
      expect(find.text('Recovered title'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Home API replacement ignores an older pending response', (
    tester,
  ) async {
    final replacement = _Responses();
    addTearDown(replacement.api.close);
    await tester.pumpWidget(
      _screen(HomeScreen(api: responses.api, library: library)),
    );
    await tester.pumpWidget(
      _screen(HomeScreen(api: replacement.api, library: library)),
    );
    _expectLoader(tester, 'Loading your home');
    responses.complete(0, _home('Old server title'));
    await _flush(tester);
    _expectLoader(tester, 'Loading your home');
    replacement.complete(0, _home('New server title'));
    await tester.pumpAndSettle();
    expect(find.text('New server title'), findsOneWidget);
    expect(find.text('Old server title'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final search in [false, true]) {
    final name = search ? 'Search' : 'Catalog';
    testWidgets('$name loading, error, retry and pagination preserve titles', (
      tester,
    ) async {
      await tester.pumpWidget(
        _screen(
          search
              ? SearchScreen(api: responses.api, library: library)
              : CatalogScreen(
                  api: responses.api,
                  library: library,
                  name: 'movies',
                  label: 'Movies',
                ),
        ),
      );
      if (search) {
        await tester.enterText(find.byType(TextField), 'film');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await _flush(tester);
      }
      final initialLabel = search ? 'Searching titles' : 'Loading titles';
      _expectLoader(tester, initialLabel);
      responses.fail(0);
      await tester.pumpAndSettle();
      expect(find.text('Server unavailable'), findsOneWidget);
      expect(find.byType(MovieBoxLoader), findsNothing);
      await tester.tap(find.text('Try again'));
      await _flush(tester);
      _expectLoader(tester, initialLabel);
      responses.complete(1, _page('First title', next: 2));
      await tester.pumpAndSettle();
      expect(find.text('First title'), findsOneWidget);

      await tester.tap(find.text('Load more'));
      await _flush(tester);
      _expectLoader(tester, 'Loading more titles', compact: true);
      expect(find.text('First title'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
      responses.fail(2);
      await tester.pumpAndSettle();
      expect(find.text('First title'), findsOneWidget);
      expect(find.text('Server unavailable'), findsOneWidget);
      expect(find.byType(MovieBoxLoader), findsNothing);
      await tester.ensureVisible(find.text('Try again'));
      await tester.tap(find.text('Try again'));
      await _flush(tester);
      _expectLoader(tester, 'Loading more titles', compact: true);
      responses.complete(3, _page('Second title'));
      await tester.pumpAndSettle();
      expect(find.text('First title'), findsOneWidget);
      expect(find.text('Second title'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
      expect(find.byType(MovieBoxLoader), findsNothing);
      expect(
        responses.requests.map(
          (request) => request.url.queryParameters['page'],
        ),
        ['1', '1', '2', '2'],
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final search in [false, true]) {
    testWidgets(
      '${search ? 'Search' : 'Catalog'} empty response stops loading',
      (tester) async {
        await tester.pumpWidget(
          _screen(
            search
                ? SearchScreen(api: responses.api, library: library)
                : CatalogScreen(
                    api: responses.api,
                    library: library,
                    name: 'movies',
                    label: 'Movies',
                  ),
          ),
        );
        if (search) {
          await tester.enterText(find.byType(TextField), 'missing');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await _flush(tester);
        }
        _expectLoader(tester, search ? 'Searching titles' : 'Loading titles');
        responses.complete(0, {'items': []});
        await tester.pumpAndSettle();
        expect(find.byType(MovieBoxLoader), findsNothing);
        expect(
          find.text(search ? 'No results found.' : 'No titles found.'),
          findsOneWidget,
        );
        expect(find.text('Load more'), findsNothing);
      },
    );
  }

  testWidgets('Catalog refresh supersedes pending pagination and can recover', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(
        CatalogScreen(
          api: responses.api,
          library: library,
          name: 'movies',
          label: 'Movies',
        ),
      ),
    );
    responses.complete(0, _page('First title', next: 2));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Load more'));
    await _flush(tester);
    final refresh = tester.widget<RefreshIndicator>(
      find.byType(RefreshIndicator),
    );
    final refreshed = refresh.onRefresh();
    await _flush(tester);
    _expectLoader(tester, 'Loading titles');
    responses.complete(1, _page('Stale pagination title'));
    await _flush(tester);
    _expectLoader(tester, 'Loading titles');
    responses.fail(2);
    await refreshed;
    await tester.pumpAndSettle();
    expect(find.text('Stale pagination title'), findsNothing);
    expect(find.text('Server unavailable'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await _flush(tester);
    _expectLoader(tester, 'Loading titles');
    responses.complete(3, _page('Refreshed title'));
    await tester.pumpAndSettle();
    expect(find.text('Refreshed title'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Catalog API replacement cannot be overwritten by old failure', (
    tester,
  ) async {
    final replacement = _Responses();
    addTearDown(replacement.api.close);
    Widget catalog(MovieApi api) => _screen(
      CatalogScreen(
        api: api,
        library: library,
        name: 'movies',
        label: 'Movies',
      ),
    );
    await tester.pumpWidget(catalog(responses.api));
    await tester.pumpWidget(catalog(replacement.api));
    _expectLoader(tester, 'Loading titles');
    responses.fail(0);
    await _flush(tester);
    _expectLoader(tester, 'Loading titles');
    expect(find.text('Server unavailable'), findsNothing);
    replacement.complete(0, _page('New server title'));
    await tester.pumpAndSettle();
    expect(find.text('New server title'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Search ignores stale responses and clears pending loading', (
    tester,
  ) async {
    await tester.pumpWidget(
      _screen(SearchScreen(api: responses.api, library: library)),
    );
    await tester.enterText(find.byType(TextField), 'old');
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    _expectLoader(tester, 'Searching titles');
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    _expectLoader(tester, 'Searching titles');
    responses.fail(0);
    await _flush(tester);
    _expectLoader(tester, 'Searching titles');
    expect(find.text('Server unavailable'), findsNothing);
    responses.complete(1, _page('New query title'));
    await tester.pumpAndSettle();
    expect(find.text('New query title'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'cancelled');
    await tester.pump(const Duration(milliseconds: 400));
    await _flush(tester);
    _expectLoader(tester, 'Searching titles');
    await tester.enterText(find.byType(TextField), '');
    await _flush(tester);
    expect(find.byType(MovieBoxLoader), findsNothing);
    responses.complete(2, _page('Cancelled title'));
    await tester.pumpAndSettle();
    expect(find.text('Cancelled title'), findsNothing);
    expect(find.text('No results found.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Details retry shows feedback and download options recover', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DetailScreen(api: responses.api, library: library, path: 'film'),
      ),
    );
    _expectLoader(tester, 'Loading details');
    responses.fail(0);
    await tester.pumpAndSettle();
    expect(find.text('Server unavailable'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await _flush(tester);
    _expectLoader(tester, 'Loading details');
    expect(find.text('Server unavailable'), findsNothing);
    responses.complete(1, {'title': _title('Film')});
    await tester.pumpAndSettle();
    expect(find.text('Film'), findsOneWidget);
    expect(find.byType(MovieBoxLoader), findsNothing);

    await tester.ensureVisible(find.text('Download MP4'));
    await tester.tap(find.text('Download MP4'));
    await _flush(tester);
    _expectLoader(tester, 'Getting download options', compact: true);
    final button = find.ancestor(
      of: find.text('Getting download options'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
    responses.fail(2);
    await tester.pumpAndSettle();
    expect(find.text('Server unavailable'), findsOneWidget);
    expect(find.byType(MovieBoxLoader), findsNothing);
    expect(find.text('Download MP4'), findsOneWidget);
    ScaffoldMessenger.of(tester.element(find.text('Download MP4')))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Download MP4'));
    await _flush(tester);
    _expectLoader(tester, 'Getting download options', compact: true);
    responses.complete(3, {
      'streams': [
        {
          'id': 'mp4',
          'format': 'MP4',
          'resolutions': '720',
          'url': 'https://example.test/video.mp4',
        },
      ],
    });
    await tester.pumpAndSettle();
    expect(find.text('Download quality'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
    expect(find.byType(MovieBoxLoader), findsNothing);
    Navigator.of(tester.element(find.text('Download quality'))).pop();
    await tester.pumpAndSettle();
    final download = find.ancestor(
      of: find.text('Download MP4'),
      matching: find.byType(OutlinedButton),
    );
    expect(tester.widget<OutlinedButton>(download).onPressed, isNotNull);

    await tester.tap(find.text('Download MP4'));
    await _flush(tester);
    _expectLoader(tester, 'Getting download options', compact: true);
    responses.complete(4, {'streams': []});
    await tester.pumpAndSettle();
    expect(
      find.text('No downloadable MP4 stream is available.'),
      findsOneWidget,
    );
    expect(find.byType(MovieBoxLoader), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Download preparation loads captions and stops when details closes',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            api: responses.api,
            library: library,
            path: 'film',
          ),
        ),
      );
      responses.complete(0, {'title': _title('Film')});
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Download MP4'));
      await tester.tap(find.text('Download MP4'));
      await _flush(tester);
      responses.complete(1, {
        'streams': [
          {
            'id': 'mp4',
            'format': 'MP4',
            'resolutions': '720',
            'url': 'https://example.test/video.mp4',
          },
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('720p'));
      await tester.pump(const Duration(milliseconds: 400));
      await _flush(tester);
      _expectLoader(tester, 'Preparing download', compact: true);
      expect(responses.requests.last.url.path, endsWith('/captions'));
      await tester.pumpWidget(const SizedBox.shrink());
      responses.complete(2, []);
      await tester.pumpAndSettle();
      expect(library.downloads, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Leaving details during download resolution does not show a sheet',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DetailScreen(
            api: responses.api,
            library: library,
            path: 'film',
          ),
        ),
      );
      responses.complete(0, {'title': _title('Film')});
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Download MP4'));
      await tester.tap(find.text('Download MP4'));
      await _flush(tester);
      _expectLoader(tester, 'Getting download options', compact: true);
      await tester.pumpWidget(const SizedBox.shrink());
      responses.fail(1);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Settings connection retry and saving show disabled labeled feedback',
    (tester) async {
      final settingsLibrary = _SavingLibrary(
        await SharedPreferences.getInstance(),
      );
      addTearDown(settingsLibrary.dispose);
      var saves = 0;
      await http.runWithClient(() async {
        await tester.pumpWidget(
          _screen(
            SettingsScreen(
              api: responses.api,
              library: settingsLibrary,
              onSaved: () => saves++,
            ),
          ),
        );
        await tester.enterText(
          find.byType(TextField).first,
          'https://new.test',
        );
        await tester.enterText(find.byType(TextField).last, 'secret');
        await tester.tap(find.text('Connect and save'));
        await _flush(tester);
        _expectLoader(tester, 'Connecting', compact: true);
        expect(
          tester
              .widget<FilledButton>(
                find.ancestor(
                  of: find.byType(MovieBoxLoader),
                  matching: find.byType(FilledButton),
                ),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester.widget<TextField>(find.byType(TextField).first).enabled,
          isFalse,
        );
        expect(
          responses.requests.single.url.toString(),
          'https://new.test/health',
        );
        expect(
          responses.requests.single.headers['Authorization'],
          'Bearer secret',
        );
        responses.fail(0);
        await tester.pumpAndSettle();
        expect(find.text('Server unavailable'), findsOneWidget);
        expect(find.byType(MovieBoxLoader), findsNothing);
        expect(saves, 0);
        ScaffoldMessenger.of(tester.element(find.text('Connect and save')))
            .removeCurrentSnackBar();
        await tester.pumpAndSettle();

        await tester.tap(find.text('Connect and save'));
        await _flush(tester);
        _expectLoader(tester, 'Connecting', compact: true);
        responses.complete(1, {'ok': true});
        await _flush(tester);
        _expectLoader(tester, 'Saving connection', compact: true);
        expect(saves, 0);
        settingsLibrary.saved.complete();
        await tester.pumpAndSettle();
        expect(find.text('Server connection saved.'), findsOneWidget);
        expect(find.byType(MovieBoxLoader), findsNothing);
        expect(settingsLibrary.server, 'https://new.test');
        expect(settingsLibrary.token, 'secret');
        expect(saves, 1);
        expect(tester.takeException(), isNull);
      }, () => responses.client);
    },
  );

  testWidgets('Settings persistence failure allows another save', (
    tester,
  ) async {
    final settingsLibrary = _SavingLibrary(
      await SharedPreferences.getInstance(),
    );
    addTearDown(settingsLibrary.dispose);
    var saves = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(
        _screen(
          SettingsScreen(
            api: responses.api,
            library: settingsLibrary,
            onSaved: () => saves++,
          ),
        ),
      );
      await tester.tap(find.text('Connect and save'));
      await _flush(tester);
      responses.complete(0, {'ok': true});
      await _flush(tester);
      _expectLoader(tester, 'Saving connection', compact: true);
      settingsLibrary.saved.completeError(Exception('Storage unavailable'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Storage unavailable'), findsOneWidget);
      expect(find.byType(MovieBoxLoader), findsNothing);
      expect(saves, 0);
      settingsLibrary.saved = Completer<void>();
      await tester.tap(find.text('Connect and save'));
      await _flush(tester);
      _expectLoader(tester, 'Connecting', compact: true);
      responses.complete(1, {'ok': true});
      await _flush(tester);
      _expectLoader(tester, 'Saving connection', compact: true);
      settingsLibrary.saved.complete();
      await tester.pumpAndSettle();
      expect(saves, 1);
      expect(find.byType(MovieBoxLoader), findsNothing);
      expect(tester.takeException(), isNull);
    }, () => responses.client);
  });

  testWidgets('Settings disposal while connecting does not save or navigate', (
    tester,
  ) async {
    var saves = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(
        _screen(
          SettingsScreen(
            api: responses.api,
            library: library,
            onSaved: () => saves++,
          ),
        ),
      );
      await tester.tap(find.text('Connect and save'));
      await _flush(tester);
      _expectLoader(tester, 'Connecting', compact: true);
      await tester.pumpWidget(const SizedBox.shrink());
      responses.complete(0, {'ok': true});
      await tester.pumpAndSettle();
      expect(saves, 0);
      expect(tester.takeException(), isNull);
    }, () => responses.client);
  });

  testWidgets('Standalone settings validates and returns only after saving', (
    tester,
  ) async {
    final settingsLibrary = _SavingLibrary(
      await SharedPreferences.getInstance(),
    );
    addTearDown(settingsLibrary.dispose);
    var saves = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsScreen(
                      api: responses.api,
                      library: settingsLibrary,
                      onSaved: () => saves++,
                      standalone: true,
                    ),
                  ),
                ),
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'invalid');
      await tester.tap(find.text('Connect and save'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a full http:// or https:// server address.'),
        findsOneWidget,
      );
      expect(responses.requests, isEmpty);
      expect(find.byType(MovieBoxLoader), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'https://new.test');
      await tester.tap(find.text('Connect and save'));
      await _flush(tester);
      _expectLoader(tester, 'Connecting', compact: true);
      responses.complete(0, {'ok': true});
      await _flush(tester);
      _expectLoader(tester, 'Saving connection', compact: true);
      expect(find.text('Server settings'), findsOneWidget);
      settingsLibrary.saved.complete();
      await tester.pumpAndSettle();
      expect(find.text('Open settings'), findsOneWidget);
      expect(find.byType(SettingsScreen), findsNothing);
      expect(saves, 1);
      expect(tester.takeException(), isNull);
    }, () => responses.client);
  });

  for (final wide in [false, true]) {
    testWidgets(
      '${wide ? 'Rail' : 'Bottom'} navigation mutes inactive page tickers',
      (tester) async {
        tester.view.physicalSize = wide
            ? const Size(1280, 720)
            : const Size(800, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await http.runWithClient(() async {
          await tester.pumpWidget(MovieBoxApp(library: library));
          _expectLoader(tester, 'Loading your home');
          final homeState = tester.state(find.byType(HomeScreen));
          final navigation = find.byType(wide ? DesktopSidebar : NavigationBar);
          for (final index in [1, 2, 3, 4, 0]) {
            final label = [
              'Home',
              'Library',
              'Search',
              'Downloads',
              'Settings',
            ][index];
            await tester.tap(
              find.descendant(
                of: navigation,
                matching: wide ? find.byTooltip(label) : find.text(label),
              ),
            );
            await _flush(tester);
            if (index != 0) await tester.pumpAndSettle();
            final stack = tester.widget<IndexedStack>(
              find.byType(IndexedStack),
            );
            expect(stack.index, index);
            expect(stack.children, hasLength(5));
            for (var child = 0; child < stack.children.length; child++) {
              expect(stack.children[child], isA<TickerMode>());
              expect(
                (stack.children[child] as TickerMode).enabled,
                child == index,
              );
            }
            expect(
              tester.state(find.byType(HomeScreen, skipOffstage: false)),
              same(homeState),
            );
          }
          responses.complete(0, _home('Loaded title'));
          await tester.pumpAndSettle();
          expect(find.text('Loaded title'), findsOneWidget);
          expect(find.byType(MovieBoxLoader), findsNothing);
          expect(tester.takeException(), isNull);
        }, () => responses.client);
      },
    );
  }
}

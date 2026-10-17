import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:movie_box_app/api.dart';
import 'package:movie_box_app/download_probe.dart';
import 'package:movie_box_app/library.dart';
import 'package:movie_box_app/loading.dart';
import 'package:movie_box_app/model.dart';
import 'package:movie_box_app/player.dart';
import 'package:movie_box_app/screens.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  final sources = <int, DataSource>{};
  final events = <int, StreamController<VideoEvent>>{};
  final positions = <int, Duration>{};
  final playing = <int, bool>{};
  final disposed = <int>[];
  final seeks = <(int, Duration)>[];
  bool failNext = false;
  bool autoInitialize = true;

  void initializePlayer(int playerId) {
    events[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 10),
        size: const Size(1920, 1080),
      ),
    );
  }

  void buffer(int playerId, {required bool buffering}) {
    events[playerId]!.add(
      VideoEvent(
        eventType: buffering
            ? VideoEventType.bufferingStart
            : VideoEventType.bufferingEnd,
      ),
    );
  }

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = sources.length + 1;
    sources[id] = options.dataSource;
    positions[id] = Duration.zero;
    final stream = events[id] = StreamController<VideoEvent>();
    if (failNext) {
      failNext = false;
      stream.addError(
        PlatformException(
          code: 'VideoError',
          message: 'Fixture decoder failure',
        ),
      );
    } else if (autoInitialize) {
      initializePlayer(id);
    }
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => events[playerId]!.stream;

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await events[playerId]!.close();
  }

  @override
  Future<void> play(int playerId) async => playing[playerId] = true;

  @override
  Future<void> pause(int playerId) async => playing[playerId] = false;

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    positions[playerId] = position;
    seeks.add((playerId, position));
  }

  @override
  Future<Duration> getPosition(int playerId) async => positions[playerId]!;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      SizedBox.expand(key: ValueKey('video-${options.playerId}'));
}

const _movieResourceBucket = {
  'number': 0,
  'episode_count': 0,
  'resolutions': [360, 480, 1080],
};

class _Fixture {
  final _VideoPlatform platform;
  final MovieLibrary library;
  final Directory directory;
  final requests = <Uri>[];
  bool hasServerSeasons = true;
  bool isMovie = false;
  Completer<void>? metadataGate;
  Completer<void>? playbackGate;
  bool failPlayback = false;
  MovieTitle get title => MovieTitle.fromJson({
    'id': 'regression',
    'detail_path': isMovie ? 'regression-movie' : 'regression-series',
    'kind': isMovie ? 'movie' : 'series',
    'title': isMovie ? 'Regression Movie' : 'Regression Series',
    'has_resource': true,
  });
  late final MovieApi api = MovieApi(
    baseUrl: 'https://api.example.test',
    client: MockClient((request) async {
      requests.add(request.url);
      if (request.url.path.endsWith('/captions')) {
        return http.Response('[]', 200);
      }
      if (request.url.path.endsWith('/playback')) {
        await playbackGate?.future;
        if (failPlayback) {
          return http.Response('{"detail":"Fixture stream failure"}', 503);
        }
        final season = request.url.queryParameters['season'];
        final episode = request.url.queryParameters['episode'];
        if (isMovie && (season != '0' || episode != '0')) {
          return http.Response('{"streams": []}', 200);
        }
        return http.Response(
          jsonEncode({
            'streams': [
              for (final item in [
                ('360', 'MP4', false),
                ('1080', 'mp4', false),
                ('720', 'MP4', false),
                ('2160', 'MP4', true),
                ('4320', 'HLS', false),
              ])
                {
                  'id': '${item.$1}-$season-$episode-${requests.length}',
                  'format': item.$2,
                  'resolutions': item.$1,
                  'vip_locked': item.$3,
                  'url':
                      'https://video.example.test/s$season-e$episode-${item.$1}.mp4?revision=${requests.length}',
                  'request_headers': {'Referer': 'https://origin.example.test'},
                },
            ],
          }),
          200,
        );
      }
      await metadataGate?.future;
      return http.Response(
        jsonEncode({
          'title': title.toJson(),
          'seasons': [
            if (isMovie)
              _movieResourceBucket
            else if (hasServerSeasons) ...[
              {'number': 1, 'episode_count': 3},
              {'number': 2, 'episode_count': 2},
            ],
          ],
          'dubs': [],
        }),
        200,
      );
    }),
  );

  _Fixture(this.platform, this.library, this.directory);

  SavedDownload saved(int season, int episode, {bool subtitles = true}) {
    final video = File('${directory.path}/s$season-e$episode.mp4')
      ..writeAsBytesSync([0]);
    final caption = File('${video.path}.srt');
    if (subtitles) {
      caption.writeAsStringSync(
        '1\n00:00:01,000 --> 00:05:00,000\nOffline caption\nsecond line\n',
      );
    }
    return SavedDownload(
      title,
      season,
      episode,
      '720',
      video.path,
      subtitles ? caption.path : null,
    );
  }

  List<Uri> get playbackRequests =>
      requests.where((uri) => uri.path.endsWith('/playback')).toList();
}

VideoPlayerController _controller(WidgetTester tester) =>
    tester.widget<VideoPlayer>(find.byType(VideoPlayer)).controller;

Future<void> _chooseSubtitle(WidgetTester tester, String label) async {
  final menu = find.byType(DropdownButton<Object>);
  await tester.scrollUntilVisible(
    menu,
    120,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
    // File checks and subtitle reads run outside the widget fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  fail('Player did not reach the expected state within 80 pumps.');
}

Future<void> _mountScreen(
  WidgetTester tester,
  Widget screen, {
  Size size = const Size(1280, 720),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'Roboto',
        platform: TargetPlatform.android,
      ),
      home: screen,
    ),
  );
}

Future<void> _mountDetails(
  WidgetTester tester,
  _Fixture fixture, {
  Size size = const Size(390, 844),
}) async {
  await _mountScreen(
    tester,
    DetailScreen(
      api: fixture.api,
      library: fixture.library,
      path: fixture.title.path,
    ),
    size: size,
  );
  await tester.pumpAndSettle();
  expect(find.text('Title details'), findsOneWidget);
  expect(find.text(fixture.title.title), findsOneWidget);
}

Future<void> _mount(
  WidgetTester tester,
  _Fixture fixture, {
  Size size = const Size(1280, 720),
  SavedDownload? offline,
  int season = 1,
  int episode = 2,
}) async {
  await _mountScreen(
    tester,
    PlayerScreen(
      api: fixture.api,
      library: fixture.library,
      title: fixture.title,
      season: season,
      episode: episode,
      offline: offline,
    ),
    size: size,
  );
  await _waitForPlayback(tester, offline: offline);
}

Future<void> _waitForPlayback(
  WidgetTester tester, {
  SavedDownload? offline,
}) async {
  await _until(
    tester,
    () =>
        find.byType(VideoPlayer).evaluate().isNotEmpty &&
        find.textContaining('Subtitles:').evaluate().isNotEmpty,
  );
  if (offline?.subtitlePath != null) {
    await _until(
      tester,
      () => find.textContaining('Saved subtitles').evaluate().isNotEmpty,
    );
  }
  await tester.pumpAndSettle();
  expect(_controller(tester).value.isInitialized, isTrue);
  expect(find.byType(CircularProgressIndicator), findsNothing);
}

Future<void> _focusIcon(WidgetTester tester, IconData icon) async {
  Focus.of(tester.element(find.byIcon(icon))).requestFocus();
  await tester.pump();
  expect(Focus.of(tester.element(find.byIcon(icon))).hasPrimaryFocus, isTrue);
}

Future<void> _quality(
  WidgetTester tester,
  String resolution, {
  bool Function()? completed,
}) async {
  await tester.tap(find.textContaining('Quality ').first);
  await tester.pumpAndSettle();
  expect(find.text('Playback quality'), findsOneWidget);
  expect(find.text('2160p'), findsNothing);
  expect(find.text('4320p'), findsNothing);
  await tester.tap(find.widgetWithText(ListTile, '${resolution}p'));
  await _until(
    tester,
    completed ??
        () => find.text('Quality ${resolution}p').evaluate().isNotEmpty,
  );
  await tester.pumpAndSettle();
}

Future<void> _enterPhoneFullscreen(WidgetTester tester, Size size) async {
  expect(tester.view.physicalSize, const Size(390, 844));
  await tester.tap(find.byTooltip('Fullscreen'));
  await _until(tester, () => find.byType(AppBar).evaluate().isEmpty);
  await tester.pumpAndSettle();
  tester.view.physicalSize = size;
  await tester.pumpAndSettle();
  expect(find.byType(AppBar), findsNothing);
}

Future<void> _showFullscreenControl(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  expect(tester.takeException(), isNull);
}

Finder get _episodeSelector =>
    find.byKey(const ValueKey('mobile-episode-selector'));

void _expectEpisodes(
  WidgetTester tester,
  (int, int) selected,
  List<(int, int)> options, {
  bool includeSeason = false,
}) {
  expect(_episodeSelector, findsOneWidget);
  final dropdown = tester.widget<DropdownButton<(int, int)>>(_episodeSelector);
  expect(dropdown.value, selected);
  expect(dropdown.items!.map((item) => item.value), options);
  expect(dropdown.items!.map((item) => (item.child as Text).data), [
    for (final item in options)
      '${includeSeason ? 'S${item.$1} · ' : ''}Episode ${item.$2}',
  ]);
  expect(find.byType(ChoiceChip), findsNothing);
}

Future<void> _chooseDropdown(
  WidgetTester tester,
  Finder selector,
  String label,
) async {
  final previous = _controller(tester);
  await tester.ensureVisible(selector);
  await tester.pumpAndSettle();
  await tester.tap(selector);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).hitTestable().last);
  await _until(
    tester,
    () =>
        find.byType(VideoPlayer).evaluate().isNotEmpty &&
        _controller(tester) != previous &&
        _controller(tester).value.isInitialized &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find.byType(MovieBoxLoader).evaluate().isEmpty,
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

void _expectNoEpisodeSelectors() {
  expect(find.text('Episodes'), findsNothing);
  expect(_episodeSelector, findsNothing);
  expect(find.byType(DropdownButton<int>), findsNothing);
  expect(find.byType(ChoiceChip), findsNothing);
  expect(find.textContaining('Season '), findsNothing);
  expect(find.textContaining('Episode '), findsNothing);
}

void _expectMoviePlayback(WidgetTester tester, _Fixture fixture) {
  final player = _controller(tester);
  expect(player.value.isInitialized, isTrue);
  expect(player.value.isPlaying, isTrue);
  expect(fixture.platform.playing[player.playerId], isTrue);
  expect(
    fixture.platform.sources[player.playerId]!.uri,
    contains('s0-e0-1080.mp4'),
  );
  expect(fixture.playbackRequests.single.queryParameters, {
    'season': '0',
    'episode': '0',
  });
  final captions = fixture.requests
      .where((uri) => uri.path.endsWith('/captions'))
      .single;
  expect(captions.queryParameters['season'], '0');
  expect(captions.queryParameters['episode'], '0');
  expect(tester.takeException(), isNull);
}

Finder _loader(String label) => find.byWidgetPredicate(
  (widget) => widget is MovieBoxLoader && widget.label == label,
);

void _expectLoader(WidgetTester tester, String label) {
  expect(find.byType(MovieBoxLoader), findsOneWidget);
  expect(_loader(label), findsOneWidget);
  final text = find.descendant(of: _loader(label), matching: find.text(label));
  expect(text, findsOneWidget);
  final rect = tester.getRect(text);
  final viewport = Offset.zero & tester.view.physicalSize;
  expect(rect.width, greaterThan(0));
  expect(rect.height, greaterThan(0));
  expect(viewport.contains(rect.topLeft), isTrue);
  expect(viewport.contains(rect.bottomRight), isTrue);
  expect(tester.takeException(), isNull);
}

Future<void> _pumpLoading(WidgetTester tester) async {
  // Native events arrive asynchronously; no playhead tick is needed.
  await tester.pump();
  await tester.pump();
}

void main() {
  late _Fixture fixture;
  late VideoPlayerPlatform originalPlatform;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Ahem's square glyphs produce false TV control overflows.
    final configFile = File('.dart_tool/package_config.json');
    final config =
        jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    final package = (config['packages'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((entry) => entry['name'] == 'flutter');
    final flutter = configFile.absolute.uri.resolve('${package['rootUri']}/');
    final loader = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      final font = File.fromUri(
        flutter.resolve(
          '../../bin/cache/artifacts/material_fonts/Roboto-$weight.ttf',
        ),
      );
      loader.addFont(
        Future.value(ByteData.sublistView(font.readAsBytesSync())),
      );
    }
    await loader.load();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    originalPlatform = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    fixture = _Fixture(
      platform,
      MovieLibrary(await SharedPreferences.getInstance()),
      Directory.systemTemp.createTempSync('moviebox-player-regression-'),
    );
  });

  tearDown(() {
    fixture.api.close();
    fixture.directory.deleteSync(recursive: true);
    VideoPlayerPlatform.instance = originalPlatform;
  });

  testWidgets('Linux keeps window navigation and uses native fullscreen', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      mediaChannel,
      (call) async { calls.add(call); return null; },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(mediaChannel, null);
    });
    await _mountScreen(tester, PlayerScreen(
      api: fixture.api, library: fixture.library, title: fixture.title,
      season: 1, episode: 2,
    ));
    await _until(tester, () => find.byType(VideoPlayer).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
    await tester.tap(find.byTooltip('Fullscreen'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'setFullscreen').last.arguments, true);
    expect(find.byType(AppBar), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'setFullscreen').last.arguments, false);
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));

  group('player loading', () {
    for (final size in [const Size(390, 844), const Size(960, 540)]) {
      testWidgets(
        'Opening video spans metadata, stream lookup, and decoder at $size',
        (tester) async {
          final metadata = fixture.metadataGate = Completer<void>();
          final playback = fixture.playbackGate = Completer<void>();
          fixture.platform.autoInitialize = false;
          await _mountScreen(
            tester,
            PlayerScreen(
              api: fixture.api,
              library: fixture.library,
              title: fixture.title,
              season: 1,
              episode: 2,
            ),
            size: size,
          );
          await _pumpLoading(tester);
          _expectLoader(tester, 'Opening video');
          expect(fixture.platform.sources, isEmpty);
          expect(find.byType(VideoPlayer), findsNothing);
          expect(find.text('Try again'), findsNothing);

          metadata.complete();
          await tester.pump(const Duration(milliseconds: 100));
          _expectLoader(tester, 'Opening video');
          expect(fixture.playbackRequests, hasLength(1));
          expect(fixture.platform.sources, isEmpty);

          playback.complete();
          await _until(tester, () => fixture.platform.sources.isNotEmpty);
          _expectLoader(tester, 'Opening video');
          expect(find.byType(VideoPlayer), findsNothing);
          fixture.platform.initializePlayer(
            fixture.platform.sources.keys.single,
          );
          await _until(
            tester,
            () => find.byType(VideoPlayer).evaluate().isNotEmpty,
          );
          await _pumpLoading(tester);
          expect(find.byType(MovieBoxLoader), findsNothing);
          expect(_controller(tester).value.isInitialized, isTrue);
          expect(_controller(tester).value.isPlaying, isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('Loading episode persists through lookup and decoder', (
      tester,
    ) async {
      await _mount(tester, fixture, size: const Size(960, 540));
      final previous = _controller(tester);
      final oldId = previous.playerId;
      final playback = fixture.playbackGate = Completer<void>();
      fixture.platform.autoInitialize = false;
      await tester.tap(find.text('Next'));
      await _until(tester, () => fixture.playbackRequests.length == 2);
      _expectLoader(tester, 'Loading episode');
      expect(find.text('Opening video'), findsNothing);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(fixture.platform.disposed, contains(oldId));
      expect(fixture.playbackRequests.last.queryParameters, {
        'season': '1',
        'episode': '3',
      });

      playback.complete();
      await _until(tester, () => fixture.platform.sources.length == 2);
      _expectLoader(tester, 'Loading episode');
      fixture.platform.initializePlayer(fixture.platform.sources.keys.last);
      await _until(
        tester,
        () => find.byType(VideoPlayer).evaluate().isNotEmpty,
      );
      await _pumpLoading(tester);
      expect(find.byType(MovieBoxLoader), findsNothing);
      expect(_controller(tester), isNot(same(previous)));
      expect(_controller(tester).value.isPlaying, isTrue);
      expect(find.text('Regression Series · S1 E3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final mode in ['portrait', 'fullscreen', 'TV']) {
      testWidgets('$mode Switching quality keeps the original video visible', (
        tester,
      ) async {
        await _mount(
          tester,
          fixture,
          size: mode == 'TV' ? const Size(960, 540) : const Size(390, 844),
        );
        if (mode == 'fullscreen') {
          await _enterPhoneFullscreen(tester, const Size(640, 360));
        }
        final previous = _controller(tester);
        final oldId = previous.playerId;
        await previous.seekTo(const Duration(seconds: 87));
        final quality = find.text('Quality 1080p');
        await tester.ensureVisible(quality);
        await tester.tap(quality);
        await tester.pumpAndSettle();
        final playback = fixture.playbackGate = Completer<void>();
        fixture.platform.autoInitialize = false;
        await tester.tap(find.widgetWithText(ListTile, '720p'));
        await _until(tester, () => fixture.playbackRequests.length == 2);
        await tester.pump(const Duration(milliseconds: 400));
        _expectLoader(tester, 'Switching quality');
        expect(_controller(tester), same(previous));
        expect(previous.value.isInitialized, isTrue);
        expect(find.byKey(ValueKey('video-$oldId')), findsOneWidget);
        expect(fixture.platform.disposed, isNot(contains(oldId)));

        playback.complete();
        await _until(tester, () => fixture.platform.sources.length == 2);
        _expectLoader(tester, 'Switching quality');
        expect(_controller(tester), same(previous));
        expect(fixture.platform.disposed, isNot(contains(oldId)));
        fixture.platform.initializePlayer(fixture.platform.sources.keys.last);
        await _until(
          tester,
          () =>
              _controller(tester) != previous &&
              find.byType(MovieBoxLoader).evaluate().isEmpty,
        );
        await _pumpLoading(tester);
        expect(find.byType(MovieBoxLoader), findsNothing);
        expect(find.text('Quality 720p'), findsOneWidget);
        expect(_controller(tester).value.position, const Duration(seconds: 87));
        expect(fixture.platform.disposed, contains(oldId));
        expect(tester.takeException(), isNull);
      });

      for (final hidden in [false, true]) {
        testWidgets(
          '$mode native buffering updates with ${hidden ? 'hidden' : 'visible'} controls and unchanged playhead',
          (tester) async {
            await _mount(
              tester,
              fixture,
              size: mode == 'TV' ? const Size(960, 540) : const Size(390, 844),
            );
            if (mode == 'fullscreen') {
              await _enterPhoneFullscreen(tester, const Size(640, 360));
            }
            final player = _controller(tester);
            if (hidden) {
              await tester.pump(const Duration(seconds: 9));
            }
            expect(
              find.byTooltip('Pause'),
              hidden ? findsNothing : findsOneWidget,
            );
            expect(find.byType(MovieBoxLoader), findsNothing);
            final position = player.value.position;
            final requests = fixture.requests.length;
            for (var cycle = 0; cycle < 2; cycle++) {
              fixture.platform.buffer(player.playerId, buffering: true);
              await _pumpLoading(tester);
              expect(player.value.isBuffering, isTrue);
              expect(player.value.position, position);
              _expectLoader(tester, 'Buffering video');
              expect(
                find.byTooltip('Pause'),
                hidden ? findsNothing : findsOneWidget,
              );
              expect(_controller(tester), same(player));
              expect(
                find.byKey(ValueKey('video-${player.playerId}')),
                findsOneWidget,
              );

              fixture.platform.buffer(player.playerId, buffering: false);
              await _pumpLoading(tester);
              expect(player.value.isBuffering, isFalse);
              expect(player.value.position, position);
              expect(find.byType(MovieBoxLoader), findsNothing);
              expect(find.text('Buffering video'), findsNothing);
              expect(
                find.byTooltip('Pause'),
                hidden ? findsNothing : findsOneWidget,
              );
            }
            expect(fixture.requests, hasLength(requests));
            expect(fixture.platform.sources, hasLength(1));
            expect(fixture.platform.disposed, isEmpty);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    for (final failure in ['stream', 'decoder']) {
      testWidgets('initial $failure error replaces loader and retry recovers', (
        tester,
      ) async {
        fixture.failPlayback = failure == 'stream';
        fixture.platform.failNext = failure == 'decoder';
        await _mountScreen(
          tester,
          PlayerScreen(
            api: fixture.api,
            library: fixture.library,
            title: fixture.title,
            season: 1,
            episode: 2,
          ),
          size: const Size(390, 844),
        );
        await _until(
          tester,
          () => find.text('Try again').evaluate().isNotEmpty,
        );
        expect(find.byType(MovieBoxLoader), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(VideoPlayer), findsNothing);
        expect(find.textContaining('Fixture $failure failure'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Try again'), findsOneWidget);
        expect(find.byType(MovieBoxLoader), findsNothing);

        fixture.failPlayback = false;
        final playback = fixture.playbackGate = Completer<void>();
        await tester.tap(find.text('Try again'));
        await _pumpLoading(tester);
        _expectLoader(tester, 'Opening video');
        expect(find.text('Try again'), findsNothing);
        playback.complete();
        await _until(
          tester,
          () => find.byType(VideoPlayer).evaluate().isNotEmpty,
        );
        await _pumpLoading(tester);
        expect(find.byType(MovieBoxLoader), findsNothing);
        expect(find.text('Try again'), findsNothing);
        expect(_controller(tester).value.isInitialized, isTrue);
        expect(_controller(tester).value.isPlaying, isTrue);
        expect(fixture.playbackRequests, hasLength(2));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('movie regression', () {
    test('model excludes the live movie resource bucket', () {
      fixture.isMovie = true;
      final detail = MovieDetail.fromJson({
        'title': fixture.title.toJson(),
        'seasons': [_movieResourceBucket],
      });

      expect(detail.title.kind, 'movie');
      expect(detail.seasons, isEmpty);
    });

    test('model excludes even positive episode seasons for movies', () {
      fixture.isMovie = true;
      final detail = MovieDetail.fromJson({
        'title': fixture.title.toJson(),
        'seasons': [
          _movieResourceBucket,
          {'number': 1, 'episode_count': 3},
        ],
      });

      expect(detail.seasons, isEmpty);
    });

    for (final kind in ['series', 'dub']) {
      test(
        'model retains real $kind seasons and rejects zero or empty ones',
        () {
          final detail = MovieDetail.fromJson({
            'title': {...fixture.title.toJson(), 'kind': kind},
            'seasons': [
              _movieResourceBucket,
              {'number': 0, 'episode_count': 2},
              {'number': 3, 'episode_count': 0},
              {
                'number': 1,
                'episode_count': 3,
                'resolutions': [360, 720, 1080],
              },
              {'number': 2, 'episode_count': 2},
            ],
          });

          expect(
            detail.seasons.map((season) => (season.number, season.episodes)),
            [(1, 3), (2, 2)],
          );
          expect(detail.seasons.first.resolutions, [360, 720, 1080]);
          expect(detail.seasons.last.resolutions, isEmpty);
        },
      );
    }

    for (final tv in [false, true]) {
      testWidgets(
        'details Play initializes 0/0 without selectors in ${tv ? 'TV' : 'portrait and fullscreen'} despite stray downloads',
        (tester) async {
          fixture.isMovie = true;
          for (final saved in [fixture.saved(1, 1), fixture.saved(2, 2)]) {
            await fixture.library.addDownload(saved);
          }
          await _mountDetails(
            tester,
            fixture,
            size: tv ? const Size(960, 540) : const Size(390, 844),
          );
          _expectNoEpisodeSelectors();
          expect(fixture.playbackRequests, isEmpty);
          final play = find.widgetWithText(FilledButton, 'Play');
          await tester.ensureVisible(play);
          await tester.tap(play);
          await _waitForPlayback(tester);

          final screen = tester.widget<PlayerScreen>(find.byType(PlayerScreen));
          expect(screen.title.kind, 'movie');
          expect((screen.season, screen.episode), (0, 0));
          _expectMoviePlayback(tester, fixture);
          _expectNoEpisodeSelectors();
          expect(find.byType(AppBar), tv ? findsNothing : findsOneWidget);

          if (!tv) {
            final player = _controller(tester);
            await _enterPhoneFullscreen(tester, const Size(844, 390));
            expect(_controller(tester), same(player));
            expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
            _expectMoviePlayback(tester, fixture);
            _expectNoEpisodeSelectors();
          } else {
            expect(find.widgetWithText(TextButton, 'Back'), findsOneWidget);
            expect(find.byTooltip('Fullscreen'), findsNothing);
          }
          expect(fixture.platform.sources, hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('details download picker requests movie 0/0', (tester) async {
      fixture.isMovie = true;
      await _mountDetails(tester, fixture);
      _expectNoEpisodeSelectors();
      final download = find.widgetWithText(OutlinedButton, 'Download MP4');
      await tester.ensureVisible(download);
      await tester.tap(download);
      await tester.pumpAndSettle();

      expect(find.text('Download quality'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '1080p'), findsOneWidget);
      expect(fixture.playbackRequests.single.queryParameters, {
        'season': '0',
        'episode': '0',
      });
      expect(fixture.platform.sources, isEmpty);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.text('Download quality'))).pop();
      await tester.pumpAndSettle();
    });

    for (final stale in [(0, 1), (2, 3)]) {
      testWidgets(
        'direct Player normalizes stale ${stale.$1}/${stale.$2} movie arguments to 0/0',
        (tester) async {
          fixture.isMovie = true;
          await _mount(
            tester,
            fixture,
            size: const Size(390, 844),
            season: stale.$1,
            episode: stale.$2,
          );

          _expectMoviePlayback(tester, fixture);
          _expectNoEpisodeSelectors();
          expect(fixture.platform.sources, hasLength(1));
        },
      );
    }
  });

  group('shared fullscreen', () {
    for (final size in [const Size(844, 390), const Size(640, 360)]) {
      testWidgets(
        'phone controls fit ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          await _mount(tester, fixture, size: const Size(390, 844));
          final player = _controller(tester);
          await player.pause();
          await _enterPhoneFullscreen(tester, size);

          expect(_controller(tester), same(player));
          expect(find.text('Regression Series · S1 E2'), findsOneWidget);
          expect(tester.takeException(), isNull);
          for (final label in [
            'Previous',
            'Next',
            'Quality 1080p',
            'Subtitles: Off',
          ]) {
            await _showFullscreenControl(tester, find.text(label));
          }
          await _showFullscreenControl(tester, _episodeSelector);
          _expectEpisodes(tester, (1, 2), [(1, 1), (1, 2), (1, 3)]);
          final actionRow = find
              .ancestor(of: _episodeSelector, matching: find.byType(Row))
              .first;
          expect(
            find.descendant(
              of: actionRow,
              matching: find.byType(DropdownButton<int>),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: actionRow, matching: find.text('Next')),
            findsOneWidget,
          );
          final scroll = tester.widget<SingleChildScrollView>(
            find
                .ancestor(
                  of: actionRow,
                  matching: find.byType(SingleChildScrollView),
                )
                .first,
          );
          expect(scroll.scrollDirection, Axis.horizontal);
          expect(find.byType(ListView), findsNothing);
          await _showFullscreenControl(
            tester,
            find.byTooltip('Exit fullscreen'),
          );
          await _showFullscreenControl(tester, find.text('Quality 1080p'));
          await tester.tap(find.text('Quality 1080p'));
          await tester.pumpAndSettle();
          expect(find.text('Playback quality'), findsOneWidget);
          expect(find.widgetWithText(ListTile, '720p'), findsOneWidget);
          expect(find.text('2160p'), findsNothing);
          expect(find.text('4320p'), findsNothing);
          expect(tester.takeException(), isNull);
          Navigator.of(tester.element(find.text('Playback quality'))).pop();
          await tester.pumpAndSettle();
          expect(_controller(tester), same(player));
          expect(player.value.isPlaying, isFalse);
          expect(fixture.platform.sources, hasLength(1));
        },
      );
    }

    for (final exit in ['explicit control', 'header Back', 'platform Back']) {
      testWidgets('phone $exit restores portrait and paused captions', (
        tester,
      ) async {
        final platformCalls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            platformCalls.add(call);
            return null;
          },
        );
        addTearDown(() {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          );
        });
        await _mount(
          tester,
          fixture,
          size: const Size(390, 844),
          offline: fixture.saved(1, 2),
        );
        final player = _controller(tester);
        await player.pause();
        await player.seekTo(const Duration(seconds: 42));
        await tester.pump();
        expect(player.value.caption.text, 'Offline caption\nsecond line');
        await _enterPhoneFullscreen(tester, const Size(844, 390));
        expect(_controller(tester), same(player));
        expect(player.value.isPlaying, isFalse);
        expect(player.value.position, const Duration(seconds: 42));
        expect(find.text('Offline caption\nsecond line'), findsOneWidget);
        expect(
          platformCalls
              .where(
                (call) =>
                    call.method == 'SystemChrome.setPreferredOrientations',
              )
              .last
              .arguments,
          [
            'DeviceOrientation.landscapeLeft',
            'DeviceOrientation.landscapeRight',
          ],
        );
        platformCalls.clear();

        if (exit == 'platform Back') {
          await tester.binding.handlePopRoute();
        } else {
          final control = exit == 'header Back'
              ? find.widgetWithText(TextButton, 'Back')
              : find.byTooltip('Exit fullscreen');
          await _showFullscreenControl(tester, control);
          await tester.tap(control);
        }
        await tester.pumpAndSettle();
        expect(
          platformCalls
              .where(
                (call) =>
                    call.method == 'SystemChrome.setPreferredOrientations',
              )
              .last
              .arguments,
          ['DeviceOrientation.portraitUp'],
        );
        expect(
          platformCalls
              .where(
                (call) => call.method == 'SystemChrome.setEnabledSystemUIMode',
              )
              .last
              .arguments,
          'SystemUiMode.edgeToEdge',
        );
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();

        expect(find.byType(PlayerScreen), findsOneWidget);
        expect(
          find.widgetWithText(AppBar, 'Regression Series'),
          findsOneWidget,
        );
        expect(find.byTooltip('Fullscreen'), findsOneWidget);
        expect(find.byTooltip('Exit fullscreen'), findsNothing);
        expect(find.textContaining('Offline · 720p'), findsOneWidget);
        expect(_controller(tester), same(player));
        expect(fixture.platform.sources, hasLength(1));
        expect(fixture.platform.disposed, isEmpty);
        expect(fixture.platform.playing[player.playerId], isFalse);
        expect(player.value.isPlaying, isFalse);
        expect(player.value.position, const Duration(seconds: 42));
        expect(player.value.caption.text, 'Offline caption\nsecond line');
        expect(find.text('Offline caption\nsecond line'), findsOneWidget);
        expect(fixture.playbackRequests, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('phone saved captions menu switches Off and restores offline', (
      tester,
    ) async {
      await _mount(
        tester,
        fixture,
        size: const Size(390, 844),
        offline: fixture.saved(1, 2),
      );
      final player = _controller(tester);
      await player.pause();
      await player.seekTo(const Duration(seconds: 2));
      await _enterPhoneFullscreen(tester, const Size(640, 360));
      final requests = fixture.requests.length;
      for (final selection in ['Off', 'Saved subtitles']) {
        final label = selection == 'Off' ? 'Saved subtitles' : 'Off';
        final control = find.text('Subtitles: $label');
        await _showFullscreenControl(tester, control);
        await tester.tap(control);
        await _until(
          tester,
          () => find.text('Language').evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(find.text('Subtitles'), findsOneWidget);
        expect(find.byType(DropdownButton<Object>), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _chooseSubtitle(tester, selection);
        await _until(
          tester,
          () => find.text('Subtitles: $selection').evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        expect(
          player.value.caption.text,
          selection == 'Off' ? isEmpty : 'Offline caption\nsecond line',
        );
        expect(
          find.text('Offline caption\nsecond line'),
          selection == 'Off' ? findsNothing : findsOneWidget,
        );
        expect(_controller(tester), same(player));
        expect(player.value.isPlaying, isFalse);
        expect(player.value.position, const Duration(seconds: 2));
        expect(find.byType(AppBar), findsNothing);
        expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(fixture.requests, hasLength(requests));
      expect(fixture.playbackRequests, isEmpty);
      expect(fixture.platform.sources, hasLength(1));
    });

    testWidgets('phone Next changes episode without leaving fullscreen', (
      tester,
    ) async {
      await _mount(tester, fixture, size: const Size(390, 844));
      final previous = _controller(tester);
      await previous.seekTo(const Duration(seconds: 123));
      await _enterPhoneFullscreen(tester, const Size(640, 360));
      await _showFullscreenControl(tester, find.text('Next'));
      await tester.tap(find.text('Next'));
      await _until(
        tester,
        () =>
            find.text('Regression Series · S1 E3').evaluate().isNotEmpty &&
            find.byType(VideoPlayer).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();

      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
      expect(tester.view.physicalSize, const Size(640, 360));
      expect(_controller(tester), isNot(same(previous)));
      expect(_controller(tester).value.isPlaying, isTrue);
      expect(fixture.platform.disposed, contains(previous.playerId));
      expect(
        fixture.platform.sources[_controller(tester).playerId]!.uri,
        contains('s1-e3-1080.mp4'),
      );
      expect(fixture.playbackRequests.last.queryParameters, {
        'season': '1',
        'episode': '3',
      });
      expect(
        fixture.library.history['regression-series:1:2']!.positionSeconds,
        123,
      );
      await _showFullscreenControl(tester, _episodeSelector);
      _expectEpisodes(tester, (1, 3), [(1, 1), (1, 2), (1, 3)]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TV retains shared controls without phone fullscreen actions', (
      tester,
    ) async {
      await _mount(tester, fixture, size: const Size(960, 540));
      final player = _controller(tester);
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Regression Series · S1 E2'), findsOneWidget);
      expect(_episodeSelector, findsNothing);
      expect(find.byType(ChoiceChip), findsNWidgets(3));
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Episode 2'))
            .selected,
        isTrue,
      );
      expect(find.widgetWithText(TextButton, 'Back'), findsOneWidget);
      expect(find.byTooltip('Fullscreen'), findsNothing);
      expect(find.byTooltip('Exit fullscreen'), findsNothing);
      for (final label in [
        'Previous',
        'Next',
        'Quality 1080p',
        'Subtitles: Off',
        'Episode 3',
      ]) {
        expect(find.text(label).hitTestable(), findsOneWidget);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Exit fullscreen'), findsNothing);
      expect(_controller(tester), same(player));
      expect(player.value.isPlaying, isTrue);
      expect(fixture.platform.sources, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('mobile episode dropdown', () {
    for (final chooseSeason in [false, true]) {
      final menu = chooseSeason ? 'season' : 'episode';
      testWidgets(
        'fullscreen $menu menu stays open past auto-hide while playing',
        (tester) async {
          await _mount(tester, fixture, size: const Size(390, 844));
          await _enterPhoneFullscreen(tester, const Size(640, 360));
          final previous = _controller(tester);
          expect(previous.value.isPlaying, isTrue);
          final selector = chooseSeason
              ? find.byType(DropdownButton<int>)
              : _episodeSelector;
          final label = chooseSeason ? 'Season 2' : 'Episode 3';
          await _showFullscreenControl(tester, selector);
          await tester.tap(selector);
          await tester.pumpAndSettle();
          expect(find.text(label).hitTestable(), findsOneWidget);

          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();

          expect(_controller(tester), same(previous));
          expect(previous.value.isPlaying, isTrue);
          expect(fixture.platform.playing[previous.playerId], isTrue);
          expect(selector, findsOneWidget);
          expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
          expect(find.text(label).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text(label).hitTestable());
          await _until(
            tester,
            () =>
                find.byType(VideoPlayer).evaluate().isNotEmpty &&
                _controller(tester) != previous &&
                _controller(tester).value.isInitialized,
          );
          await tester.pumpAndSettle();
          final selected = chooseSeason ? (2, 1) : (1, 3);
          _expectEpisodes(
            tester,
            selected,
            chooseSeason ? [(2, 1), (2, 2)] : [(1, 1), (1, 2), (1, 3)],
          );
          expect(fixture.playbackRequests.last.queryParameters, {
            'season': '${selected.$1}',
            'episode': '${selected.$2}',
          });
          expect(
            fixture.platform.sources[_controller(tester).playerId]!.uri,
            contains('s${selected.$1}-e${selected.$2}-1080.mp4'),
          );
          expect(_controller(tester).value.isPlaying, isTrue);
          expect(find.byType(AppBar), findsNothing);
          expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final fullscreen in [false, true]) {
      final mode = fullscreen ? 'fullscreen' : 'portrait';
      testWidgets(
        '$mode selects episodes and refreshes choices on season change',
        (tester) async {
          await _mount(tester, fixture, size: const Size(390, 844));
          if (fullscreen) {
            await _enterPhoneFullscreen(tester, const Size(640, 360));
          }
          _expectEpisodes(tester, (1, 2), [(1, 1), (1, 2), (1, 3)]);
          final previous = _controller(tester);
          await previous.seekTo(const Duration(seconds: 123));
          await _chooseDropdown(tester, _episodeSelector, 'Episode 3');
          _expectEpisodes(tester, (1, 3), [(1, 1), (1, 2), (1, 3)]);
          expect(fixture.platform.disposed, contains(previous.playerId));
          expect(
            fixture.library.history['regression-series:1:2']!.positionSeconds,
            123,
          );
          expect(fixture.playbackRequests.last.queryParameters, {
            'season': '1',
            'episode': '3',
          });
          expect(
            fixture.platform.sources[_controller(tester).playerId]!.uri,
            contains('s1-e3-1080.mp4'),
          );
          await _chooseDropdown(
            tester,
            find.byType(DropdownButton<int>),
            'Season 2',
          );
          _expectEpisodes(tester, (2, 1), [(2, 1), (2, 2)]);
          expect(fixture.playbackRequests.last.queryParameters, {
            'season': '2',
            'episode': '1',
          });
          await _chooseDropdown(tester, _episodeSelector, 'Episode 2');
          _expectEpisodes(tester, (2, 2), [(2, 1), (2, 2)]);
          expect(fixture.playbackRequests.last.queryParameters, {
            'season': '2',
            'episode': '2',
          });
          expect(_controller(tester).value.isPlaying, isTrue);
          expect(
            find.byType(AppBar),
            fullscreen ? findsNothing : findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '$mode lists saved episodes across seasons without metadata',
        (tester) async {
          fixture.hasServerSeasons = false;
          final first = fixture.saved(1, 2);
          final otherSeason = fixture.saved(2, 2);
          for (final saved in [otherSeason, first, fixture.saved(2, 1)]) {
            await fixture.library.addDownload(saved);
          }
          await _mount(
            tester,
            fixture,
            size: const Size(390, 844),
            offline: first,
          );
          if (fullscreen) {
            await _enterPhoneFullscreen(tester, const Size(640, 360));
          }
          const options = [(1, 2), (2, 1), (2, 2)];
          _expectEpisodes(tester, (1, 2), options, includeSeason: true);
          expect(find.byType(DropdownButton<int>), findsNothing);
          await _chooseDropdown(tester, _episodeSelector, 'S2 · Episode 2');
          await _until(
            tester,
            () => find.textContaining('Saved subtitles').evaluate().isNotEmpty,
          );
          _expectEpisodes(tester, (2, 2), options, includeSeason: true);
          expect(
            fixture.platform.sources[_controller(tester).playerId]!.uri,
            Uri.file(otherSeason.path).toString(),
          );
          expect(fixture.playbackRequests, isEmpty);
          await _chooseDropdown(tester, _episodeSelector, 'S1 · Episode 2');
          _expectEpisodes(tester, (1, 2), options, includeSeason: true);
          expect(
            fixture.platform.sources[_controller(tester).playerId]!.uri,
            Uri.file(first.path).toString(),
          );
          expect(fixture.playbackRequests, isEmpty);
          expect(
            find.byType(AppBar),
            fullscreen ? findsNothing : findsOneWidget,
          );
        },
      );
    }

    testWidgets('mode switching preserves dropdown selection and controller', (
      tester,
    ) async {
      await _mount(tester, fixture, size: const Size(390, 844));
      await _chooseDropdown(tester, _episodeSelector, 'Episode 3');
      final player = _controller(tester);
      await player.pause();
      await player.seekTo(const Duration(seconds: 42));
      final requests = fixture.requests.length;
      final sources = fixture.platform.sources.length;
      await tester.ensureVisible(find.byTooltip('Fullscreen'));
      await tester.pumpAndSettle();
      await _enterPhoneFullscreen(tester, const Size(844, 390));
      _expectEpisodes(tester, (1, 3), [(1, 1), (1, 2), (1, 3)]);
      expect(find.text('Regression Series · S1 E3'), findsOneWidget);
      expect(_controller(tester), same(player));
      expect(player.value.position, const Duration(seconds: 42));
      expect(player.value.isPlaying, isFalse);
      await tester.tap(find.byTooltip('Exit fullscreen'));
      await _until(tester, () => find.byType(AppBar).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      _expectEpisodes(tester, (1, 3), [(1, 1), (1, 2), (1, 3)]);
      expect(find.text('Season 1 · Episode 3'), findsOneWidget);
      expect(_controller(tester), same(player));
      expect(player.value.position, const Duration(seconds: 42));
      expect(player.value.isPlaying, isFalse);
      expect(fixture.requests, hasLength(requests));
      expect(fixture.platform.sources, hasLength(sources));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets(
    'initialized playback selects highest unlocked MP4, resumes, and forwards headers',
    (tester) async {
      await fixture.library.record(WatchEntry(fixture.title, 1, 2, 42, 600));
      await _mount(tester, fixture);
      final player = _controller(tester);
      expect(player.value.position, const Duration(seconds: 42));
      expect(player.value.isPlaying, isTrue);
      expect(fixture.platform.playing[player.playerId], isTrue);
      expect(
        fixture.platform.sources[player.playerId]!.uri,
        contains('s1-e2-1080.mp4'),
      );
      expect(
        fixture.platform.sources[player.playerId]!.httpHeaders,
        downloadRequestHeaders({'Referer': 'https://origin.example.test'}),
      );
      expect(
        fixture.platform.sources[player.playerId]!.httpHeaders['User-Agent'],
        isNot('ExoPlayer'),
      );
      expect(find.text('Quality 1080p'), findsOneWidget);
      expect(fixture.playbackRequests.single.queryParameters, {
        'season': '1',
        'episode': '2',
      });
    },
  );

  testWidgets('video surface remote keys pause, resume, and clamp seeks', (
    tester,
  ) async {
    await _mount(tester, fixture);
    final player = _controller(tester);
    for (final key in [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.select,
    ]) {
      final wasPlaying = player.value.isPlaying;
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(player.value.isPlaying, !wasPlaying);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(player.value.position, Duration.zero);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(player.value.position, const Duration(seconds: 10));
    await player.seekTo(const Duration(seconds: 595));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(player.value.position, const Duration(minutes: 10));
  });

  testWidgets('D-pad traverses center buttons without seeking', (tester) async {
    await _mount(tester, fixture);
    await _focusIcon(tester, Icons.replay_10);
    final position = _controller(tester).value.position;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      Focus.of(tester.element(find.byIcon(Icons.pause_circle))).hasPrimaryFocus,
      isTrue,
      reason:
          'Right from Back 10 seconds must focus Pause, not seek the video.',
    );
    expect(_controller(tester).value.position, position);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      Focus.of(tester.element(find.byIcon(Icons.forward_10))).hasPrimaryFocus,
      isTrue,
    );
  });

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.select]) {
    testWidgets('focused seek button activates with ${key.keyLabel}', (
      tester,
    ) async {
      await _mount(tester, fixture);
      await _focusIcon(tester, Icons.forward_10);
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(
        _controller(tester).value.position,
        const Duration(seconds: 10),
        reason: 'Activating Forward must seek, not toggle playback.',
      );
      expect(_controller(tester).value.isPlaying, isTrue);
    });
  }

  testWidgets('D-pad traverses TV episode controls and Select activates Next', (
    tester,
  ) async {
    await _mount(tester, fixture);
    Focus.of(tester.element(find.text('Previous'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(Focus.of(tester.element(find.text('Next'))).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _until(
      tester,
      () =>
          find.text('Regression Series · S1 E3').evaluate().isNotEmpty &&
          find.byType(VideoPlayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('Regression Series · S1 E3'), findsOneWidget);
    expect(
      fixture.platform.sources[_controller(tester).playerId]!.uri,
      contains('s1-e3'),
    );
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Episode 3'))
          .selected,
      isTrue,
    );
  });

  for (final size in [const Size(960, 540), const Size(1280, 720)]) {
    testWidgets(
      'initialized TV controls fit ${size.width.toInt()}x${size.height.toInt()} with saved subtitles',
      (tester) async {
        await _mount(tester, fixture, size: size, offline: fixture.saved(1, 2));
        expect(
          tester.takeException(),
          isNull,
          reason: 'Initialized TV controls must not overflow.',
        );
        final viewport = Offset.zero & size;
        for (final label in [
          'Previous',
          'Next',
          'Quality 720p',
          'Subtitles: Saved subtitles',
          'Saved',
          'Episode 3',
        ]) {
          final finder = find.text(label);
          expect(finder, findsOneWidget);
          final rect = tester.getRect(finder);
          expect(
            viewport.contains(rect.topLeft) &&
                viewport.contains(rect.bottomRight),
            isTrue,
            reason: '$label must fit inside the TV viewport.',
          );
        }
        await tester.tap(find.text('Subtitles: Saved subtitles'));
        await _until(
          tester,
          () => find.text('Language').evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        await _chooseSubtitle(tester, 'Off');
        await tester.pumpAndSettle();
        expect(find.text('Subtitles: Off'), findsOneWidget);
        await tester.tap(find.text('Subtitles: Off'));
        await _until(
          tester,
          () => find.text('Language').evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        await _chooseSubtitle(tester, 'Saved subtitles');
        await _until(
          tester,
          () => find.text('Subtitles: Saved subtitles').evaluate().isNotEmpty,
        );
        await _controller(tester).seekTo(const Duration(seconds: 2));
        await tester.pump();
        expect(find.text('Offline caption\nsecond line'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'phone offline playback loads real saved SRT without playback API requests',
    (tester) async {
      await _mount(
        tester,
        fixture,
        size: const Size(390, 844),
        offline: fixture.saved(1, 2),
      );
      final player = _controller(tester);
      expect(
        fixture.platform.sources[player.playerId]!.sourceType,
        DataSourceType.file,
      );
      expect(fixture.playbackRequests, isEmpty);
      await player.seekTo(const Duration(seconds: 2));
      await tester.pump();
      expect(player.value.caption.text, 'Offline caption\nsecond line');
      expect(find.text('Offline caption\nsecond line'), findsOneWidget);
      expect(find.textContaining('Offline · 720p'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Downloaded'),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('phone offline subtitles can be switched Off and restored', (
    tester,
  ) async {
    await _mount(
      tester,
      fixture,
      size: const Size(390, 844),
      offline: fixture.saved(1, 2),
    );
    final button = find.ancestor(
      of: find.textContaining('Saved subtitles'),
      matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
    );
    expect(
      button,
      findsOneWidget,
      reason: 'Phone offline playback needs an actionable subtitle selector, not only a status label.',
    );
    await tester.tap(button);
    await _until(
      tester,
      () => find.text('Language').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    await _chooseSubtitle(tester, 'Off');
    await tester.pumpAndSettle();
    await _controller(tester).seekTo(const Duration(seconds: 2));
    expect(_controller(tester).value.caption.text, isEmpty);
    await tester.tap(
      find
          .ancestor(
            of: find.text('Off'),
            matching: find.byWidgetPredicate(
              (widget) => widget is ButtonStyleButton,
            ),
          )
          .first,
    );
    await _until(
      tester,
      () => find.text('Language').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    await _chooseSubtitle(tester, 'Saved subtitles');
    await _until(
      tester,
      () => _controller(tester).value.caption.text.isNotEmpty,
    );
    expect(
      _controller(tester).value.caption.text,
      'Offline caption\nsecond line',
    );
  });

  testWidgets(
    'quality replacement preserves position, updates selection, and disposes old player',
    (tester) async {
      await _mount(tester, fixture);
      final previous = _controller(tester);
      final oldId = previous.playerId;
      await previous.seekTo(const Duration(seconds: 87));
      await _quality(tester, '720');
      final player = _controller(tester);
      expect(player, isNot(same(previous)));
      expect(player.value.position, const Duration(seconds: 87));
      expect(player.value.isPlaying, isTrue);
      expect(fixture.platform.disposed, contains(oldId));
      expect(find.text('Quality 720p'), findsOneWidget);
      expect(
        fixture.platform.sources[player.playerId]!.uri,
        contains('s1-e2-720.mp4'),
      );
      expect(fixture.playbackRequests, hasLength(2));
      await tester.tap(find.text('Quality 720p'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, '720p'),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      final count = fixture.platform.sources.length;
      await tester.tap(find.widgetWithText(ListTile, '720p'));
      await tester.pumpAndSettle();
      expect(fixture.platform.sources.length, count);
    },
  );

  testWidgets('quality replacement preserves paused state', (tester) async {
    await _mount(tester, fixture);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(_controller(tester).value.isPlaying, isFalse);
    await _quality(tester, '720');
    expect(
      _controller(tester).value.isPlaying,
      isFalse,
      reason: 'Changing resolution must not resume a user-paused video.',
    );
  });

  testWidgets(
    'failed quality initialization keeps the playable controller and selected quality',
    (tester) async {
      await _mount(tester, fixture);
      final previous = _controller(tester);
      final oldId = previous.playerId;
      await previous.seekTo(const Duration(seconds: 87));
      fixture.platform.failNext = true;
      await _quality(
        tester,
        '720',
        completed: () => fixture.platform.disposed.contains(2),
      );
      expect(_controller(tester), same(previous));
      expect(previous.value.isInitialized, isTrue);
      expect(previous.value.position, const Duration(seconds: 87));
      expect(find.text('Quality 1080p'), findsOneWidget);
      expect(fixture.platform.disposed, isNot(contains(oldId)));
      expect(fixture.platform.disposed, contains(2));
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets(
    'failed quality replacement retains its checkmark when refreshed stream IDs change',
    (tester) async {
      await _mount(tester, fixture);
      fixture.platform.failNext = true;
      await _quality(
        tester,
        '720',
        completed: () => fixture.platform.disposed.contains(2),
      );
      expect(find.text('Quality 1080p'), findsOneWidget);
      await tester.tap(find.text('Quality 1080p'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.widgetWithText(ListTile, '1080p'),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
        reason: 'The quality sheet must still mark the stream that remains playing after replacement fails.',
      );
    },
  );

  testWidgets(
    'changing offline quality returns to network and clears saved caption state',
    (tester) async {
      await _mount(tester, fixture, offline: fixture.saved(1, 2));
      await _controller(tester).seekTo(const Duration(seconds: 35));
      final oldId = _controller(tester).playerId;
      await _quality(tester, '360');
      expect(_controller(tester).value.position, const Duration(seconds: 35));
      expect(
        fixture.platform.sources[_controller(tester).playerId]!.sourceType,
        DataSourceType.network,
      );
      expect(fixture.platform.disposed, contains(oldId));
      expect(find.text('Subtitles: Off'), findsOneWidget);
      expect(_controller(tester).value.caption.text, isEmpty);
      expect(find.text('Saved'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Download'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'episode changes save progress, prefer downloads, cross seasons, and reset quality',
    (tester) async {
      final saved = fixture.saved(1, 3);
      await fixture.library.addDownload(saved);
      await fixture.library.record(WatchEntry(fixture.title, 1, 3, 25, 600));
      await fixture.library.record(WatchEntry(fixture.title, 2, 1, 61, 600));
      await _mount(tester, fixture);
      final oldId = _controller(tester).playerId;
      await _controller(tester).seekTo(const Duration(seconds: 123));
      await tester.tap(find.text('Next'));
      await _until(
        tester,
        () => find.text('Subtitles: Saved subtitles').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(
        fixture.library.history['regression-series:1:2']!.positionSeconds,
        123,
      );
      expect(fixture.platform.disposed, contains(oldId));
      expect(_controller(tester).value.position, const Duration(seconds: 25));
      expect(
        fixture.platform.sources[_controller(tester).playerId]!.sourceType,
        DataSourceType.file,
      );
      expect(fixture.playbackRequests, hasLength(1));
      expect(find.text('Quality 720p'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await _until(
        tester,
        () =>
            find.text('Regression Series · S2 E1').evaluate().isNotEmpty &&
            find.text('Quality 1080p').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.text('Regression Series · S2 E1'), findsOneWidget);
      expect(find.text('Quality 1080p'), findsOneWidget);
      expect(find.text('Subtitles: Off'), findsOneWidget);
      expect(_controller(tester).value.caption.text, isEmpty);
      expect(_controller(tester).value.position, const Duration(seconds: 61));
      expect(fixture.playbackRequests.last.queryParameters, {
        'season': '2',
        'episode': '1',
      });
      expect(
        fixture.platform.sources[_controller(tester).playerId]!.sourceType,
        DataSourceType.network,
      );
    },
  );

  testWidgets(
    'missing saved next episode falls back to network and last episode disables Next',
    (tester) async {
      final missing = fixture.saved(2, 2, subtitles: false);
      File(missing.path).deleteSync();
      await fixture.library.addDownload(missing);
      await _mount(tester, fixture, season: 2, episode: 1);
      await tester.tap(find.text('Next'));
      await _until(
        tester,
        () =>
            find.text('Regression Series · S2 E2').evaluate().isNotEmpty &&
            find.byType(VideoPlayer).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.text('Regression Series · S2 E2'), findsOneWidget);
      expect(
        fixture.platform.sources[_controller(tester).playerId]!.sourceType,
        DataSourceType.network,
      );
      expect(fixture.playbackRequests.last.queryParameters, {
        'season': '2',
        'episode': '2',
      });
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Next'))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'TV controls hide on idle video, reveal with D-pad, and stay visible while buttons are focused',
    (tester) async {
      await _mount(tester, fixture);
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Quality 1080p'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.text('Quality 1080p'), findsOneWidget);
      Focus.of(tester.element(find.text('Next'))).requestFocus();
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Quality 1080p'), findsOneWidget);
    },
  );

  testWidgets('a saved episode plays from disk even when opened as a stream', (
    tester,
  ) async {
    await fixture.library.addDownload(fixture.saved(1, 2));
    await _mountScreen(
      tester,
      PlayerScreen(
        api: fixture.api,
        library: fixture.library,
        title: fixture.title,
        season: 1,
        episode: 2,
      ),
    );
    await _until(
      tester,
      () =>
          find.byType(VideoPlayer).evaluate().isNotEmpty &&
          find.textContaining('Saved subtitles').evaluate().isNotEmpty,
    );
    await tester.pump();
    expect(
      fixture.platform.sources[_controller(tester).playerId]!.sourceType,
      DataSourceType.file,
    );
    expect(fixture.playbackRequests, isEmpty);
    expect(find.text('Subtitles: Saved subtitles'), findsOneWidget);
  });

  testWidgets('playback speed can be changed while a download is playing', (
    tester,
  ) async {
    await _mount(
      tester,
      fixture,
      size: const Size(390, 844),
      offline: fixture.saved(1, 2, subtitles: false),
    );
    await tester.tap(find.text('Speed 1x'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, '1.5x'));
    await tester.pumpAndSettle();
    expect(_controller(tester).value.playbackSpeed, 1.5);
    expect(find.text('Speed 1.5x'), findsOneWidget);
    expect(find.text('Off'), findsWidgets);
  });
}

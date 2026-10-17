import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:movie_box_app/desktop.dart';
import 'package:movie_box_app/library.dart';
import 'package:movie_box_app/main.dart';
import 'package:movie_box_app/player.dart';
import 'package:movie_box_app/screens.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

Future<void> waitUntil(WidgetTester tester, bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(
    ready(),
    isTrue,
    reason:
        'Timed out waiting for the Linux app. '
        'Visible text: ${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).join(' | ')}',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Linux navigation, streaming, fullscreen and offline download', (
    tester,
  ) async {
    expect(Platform.isLinux, isTrue);
    const videoPath = String.fromEnvironment('MOVIEBOX_TEST_VIDEO');
    expect(
      videoPath,
      isNotEmpty,
      reason: 'Pass --dart-define=MOVIEBOX_TEST_VIDEO=/path/to/test.mp4',
    );
    final bytes = await File(videoPath).readAsBytes();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}';
    final directory = await Directory.systemTemp.createTemp(
      'moviebox-linux-test-',
    );
    final title = <String, dynamic>{
      'id': 'linux-fixture',
      'detail_path': 'linux-fixture',
      'kind': 'movie',
      'title': 'Linux test film',
      'description': 'Generated test pattern',
      'has_resource': true,
    };
    var authorizedVideoRequests = 0;
    var offline = false;
    server.listen((request) async {
      final response = request.response;
      try {
        if (offline) {
          response.statusCode = 503;
          await response.close();
          return;
        }
        final path = request.uri.path;
        if (path == '/video.mp4') {
          if (request.headers.value('X-MovieBox-Test') != 'linux') {
            response.statusCode = 403;
            await response.close();
            return;
          }
          authorizedVideoRequests++;
          var start = 0;
          var end = bytes.length - 1;
          final range = request.headers.value(HttpHeaders.rangeHeader);
          if (range != null) {
            final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
            start = int.parse(match[1]!);
            if (match[2]!.isNotEmpty) end = min(end, int.parse(match[2]!));
            response.statusCode = 206;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${bytes.length}',
            );
          }
          response.headers
            ..contentType = ContentType('video', 'mp4')
            ..contentLength = end - start + 1
            ..set(HttpHeaders.acceptRangesHeader, 'bytes')
            ..set(HttpHeaders.etagHeader, '"linux-fixture"');
          if (request.method != 'HEAD') {
            for (var offset = start; offset <= end; offset += 8192) {
              response.add(bytes.sublist(offset, min(offset + 8192, end + 1)));
              await response.flush();
              await Future<void>.delayed(const Duration(milliseconds: 40));
            }
          }
        } else if (path == '/captions.srt') {
          response.write(
            '1\n00:00:00,000 --> 00:00:30,000\nLinux subtitle fixture\n',
          );
        } else {
          final Object body;
          if (path.endsWith('/playback')) {
            body = {
              'streams': [
                {
                  'id': '360',
                  'format': 'MP4',
                  'resolutions': '360',
                  'url': '$base/video.mp4',
                  'size_bytes': bytes.length,
                  'request_headers': {'X-MovieBox-Test': 'linux'},
                },
              ],
            };
          } else if (path.endsWith('/captions')) {
            body = [
              {
                'label': 'English',
                'language': 'en',
                'url': '$base/captions.srt',
              },
            ];
          } else if (path == '/v1/titles/linux-fixture') {
            body = {'title': title};
          } else if (path.endsWith('/suggestions') ||
              path.endsWith('/popular')) {
            body = <String>[];
          } else if (path == '/v1/home' ||
              path.startsWith('/v1/collections/')) {
            body = {
              'sections': [
                {
                  'title': 'Linux fixtures',
                  'items': [title],
                },
              ],
            };
          } else if (path == '/health') {
            body = {'status': 'ok'};
          } else {
            body = {
              'items': request.uri.queryParameters['q'] == 'missing'
                  ? []
                  : [title],
            };
          }
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(body));
        }
        await response.close();
      } on SocketException {
        // Pausing or seeking closes an in-flight media request.
      } on HttpException {
        // Cancelling a transfer closes the response early.
      }
    });

    SharedPreferences.setMockInitialValues({'server': base});
    VideoPlayerMediaKit.ensureInitialized(linux: true);
    final library = MovieLibrary(
      await SharedPreferences.getInstance(),
      downloadsDirectory: () async => directory,
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      library.dispose();
      await server.close(force: true);
      await directory.delete(recursive: true);
    });
    await tester.pumpWidget(MovieBoxApp(library: library));
    await waitUntil(
      tester,
      () => find.text('Linux fixtures').evaluate().isNotEmpty,
    );
    expect(find.byType(DesktopSidebar), findsOneWidget);

    Future<void> tap(Finder finder) async {
      await tester.ensureVisible(finder.first);
      await tester.tap(finder.first);
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> tab(String label) => tap(
      find.descendant(
        of: find.byType(DesktopSidebar),
        matching: find.byTooltip(label),
      ),
    );
    Future<void> back() => tap(find.byTooltip('Back'));

    await tab('Library');
    expect(find.textContaining('No bookmarks yet'), findsOneWidget);
    await tab('Downloads');
    expect(find.text('No downloads yet.'), findsOneWidget);
    expect(find.textContaining('Keep MovieBox running'), findsOneWidget);
    await tab('Search');
    await tester.enterText(find.byType(TextField).first, 'missing');
    await tester.pump();
    await tap(find.widgetWithText(FilledButton, 'Search'));
    await waitUntil(
      tester,
      () => find.text('No results found.').evaluate().isNotEmpty,
    );
    expect(find.byType(Poster), findsNothing);
    await tap(find.byType(TextField).first);
    await tester.enterText(find.byType(TextField).first, 'Linux');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'Linux',
    );
    await tap(find.widgetWithText(FilledButton, 'Search'));
    await waitUntil(
      tester,
      () => find.text('Linux test film').evaluate().isNotEmpty,
    );
    await tap(find.text('Linux test film'));
    await waitUntil(tester, () => find.text('Play').evaluate().isNotEmpty);
    await tap(find.text('Play'));
    await waitUntil(
      tester,
      () =>
          find.byType(VideoPlayer).evaluate().isNotEmpty &&
          tester
              .widget<VideoPlayer>(find.byType(VideoPlayer))
              .controller
              .value
              .isInitialized,
    );
    final player = tester
        .widget<VideoPlayer>(find.byType(VideoPlayer))
        .controller;
    await waitUntil(
      tester,
      () => player.value.position > const Duration(seconds: 1),
    );
    expect(player.value.hasError, isFalse);
    expect(authorizedVideoRequests, greaterThan(0));
    debugPrint('Streaming playback verified');
    await tap(find.byTooltip('Bookmark'));
    expect(library.bookmarks, hasLength(1));
    await tap(find.byTooltip('Fullscreen'));
    expect(find.byType(AppBar), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AppBar), findsOneWidget);
    debugPrint('Fullscreen and Escape verified');
    await back();
    await back();
    await tab('Library');
    expect(find.text('Linux test film'), findsOneWidget);
    await tab('Home');
    expect(find.text('Continue Watching'), findsOneWidget);
    await tab('Library');
    await tap(find.text('Linux test film'));
    await waitUntil(
      tester,
      () => find.text('Download MP4').evaluate().isNotEmpty,
    );
    await tap(find.text('Download MP4'));
    await waitUntil(tester, () => find.text('360p').evaluate().isNotEmpty);
    await tap(find.text('360p'));
    await waitUntil(
      tester,
      () => library.downloadTasks.values.any((task) => task.active),
    );
    await back();
    await tab('Downloads');
    await waitUntil(tester, () => library.downloads.isNotEmpty);
    final saved = library.downloads.values.single;
    expect(await File(saved.path).length(), bytes.length);
    expect(saved.subtitlePath, isNotNull);
    expect(
      await File(saved.subtitlePath!).readAsString(),
      contains('Linux subtitle fixture'),
    );
    final requestsBeforeOffline = authorizedVideoRequests;
    offline = true;
    await tap(find.text('Linux test film').first);
    await waitUntil(
      tester,
      () =>
          find.byType(VideoPlayer).evaluate().isNotEmpty &&
          tester
              .widget<VideoPlayer>(find.byType(VideoPlayer))
              .controller
              .value
              .isInitialized,
    );
    final local = tester
        .widget<VideoPlayer>(find.byType(VideoPlayer))
        .controller;
    expect(local.dataSourceType, DataSourceType.file);
    await waitUntil(
      tester,
      () => local.value.position > const Duration(seconds: 1),
    );
    expect(local.value.hasError, isFalse);
    expect(authorizedVideoRequests, requestsBeforeOffline);
    await back();
    offline = false;
    await tab('Settings');
    await tap(find.text('Connect and save'));
    await waitUntil(
      tester,
      () => find.text('Connect and save').evaluate().isNotEmpty,
    );
    expect(library.server, base);
    expect(find.byType(PlayerScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as native;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:movie_box_app/api.dart';
import 'package:movie_box_app/download_controls.dart';
import 'package:movie_box_app/download_probe.dart';
import 'package:movie_box_app/library.dart';
import 'package:movie_box_app/model.dart';
import 'package:movie_box_app/screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloads_test.dart' show FakeDownloadBackend;

void main() {
  late MovieLibrary library;
  late FakeDownloadBackend backend;
  late MovieApi api;
  late Directory directory;
  final title = MovieTitle.fromJson({
    'id': 'fixture',
    'detail_path': 'fixture',
    'title': 'Background fixture',
    'kind': 'movie',
    'has_resource': true,
  });
  final stream = {
    'id': '360',
    'format': 'MP4',
    'resolutions': '360',
    'url': 'https://example.test/video.mp4',
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('moviebox-ui-test-');
    SharedPreferences.setMockInitialValues({});
    backend = FakeDownloadBackend()
      ..metadata = const DownloadMetadata(10485760);
    library = MovieLibrary(
      await SharedPreferences.getInstance(),
      downloadBackend: backend,
      downloadsDirectory: () async => directory,
    );
    api = MovieApi(
      baseUrl: 'https://api.test',
      client: MockClient((request) async {
        final path = request.url.path;
        final Object response = path.endsWith('/playback')
            ? {
                'streams': [stream],
              }
            : path.endsWith('/captions')
            ? []
            : path.endsWith('/recommendations')
            ? {'items': []}
            : {'title': title.toJson()};
        return http.Response(jsonEncode(response), 200);
      }),
    );
    await library
        .taskFor(title, 0, 0)
        .start(api, library, title, 0, 0, MovieStream.fromJson(stream), null);
    await library.initializeDownloads();
  });

  tearDown(() async {
    library.dispose();
    api.close();
    await directory.delete(recursive: true);
  });

  testWidgets('Linux downloads explain the app must remain running', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LibraryScreen(api: api, library: library)),
    ));
    await tester.pump();
    expect(find.textContaining('Keep MovieBox running'), findsOneWidget);
    expect(find.textContaining('Android notifications'), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets(
    'Details and Downloads share progress without cancelling on navigation',
    (tester) async {
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final task = library.taskFor(title, 0, 0);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: LibraryScreen(api: api, library: library),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Queued'), findsOneWidget);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              DetailScreen(api: api, library: library, path: title.path),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        backend.progress(backend.enqueued.single, .5, 10485760);
        await library.initializeDownloads();
      });
      await tester.pump();
      Finder detailText(String text) => find.descendant(
        of: find.byType(DetailScreen),
        matching: find.text(text),
      );
      await tester.ensureVisible(detailText('Pause download'));
      await tester.pump();
      expect(detailText('5.0 / 10.0 MB'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Download MP4'),
            )
            .onPressed,
        isNull,
      );
      await tester.runAsync(() async {
        await tester.tap(detailText('Pause download'));
        await library.initializeDownloads();
      });
      await tester.pump();
      expect(detailText('Paused'), findsOneWidget);
      expect(detailText('Resume download'), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(task.paused, isTrue);
      expect(backend.cancelled, isEmpty);
      expect(find.text('5.0 / 10.0 MB'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Resume download'));
        await library.initializeDownloads();
      });
      await tester.pump();
      expect(backend.resumed, hasLength(1));
      expect(find.text('Queued'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Cancel download'));
        await library.initializeDownloads();
      });
      await tester.pumpAndSettle();
      expect(find.byType(DownloadControls), findsNothing);
      expect(backend.cancelled, contains(backend.enqueued.single.taskId));
      expect(find.text('No downloads yet.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Failure shows retry and cancel without an endless loading indicator',
    (tester) async {
      final task = library.taskFor(title, 0, 0);
      await tester.runAsync(() async {
        backend.status(
          backend.enqueued.single,
          native.TaskStatus.failed,
          error: native.TaskException('Connection interrupted'),
        );
        await library.initializeDownloads();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadControls(task: task)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Download failed'), findsOneWidget);
      expect(find.text('Retry download'), findsOneWidget);
      expect(find.text('Cancel download'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('Cancel download'));
        await library.initializeDownloads();
      });
      await tester.pumpAndSettle();
      expect(find.text('Retry download'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movie_box_app/library.dart';
import 'package:movie_box_app/model.dart';
import 'package:movie_box_app/screens.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late MovieLibrary library;
  final title = MovieTitle.fromJson({
    'id': 'qa',
    'detail_path': 'qa-series',
    'kind': 'series',
    'title': 'QA series',
    'has_resource': true,
  });

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('moviebox-library-test-');
    SharedPreferences.setMockInitialValues({});
    library = MovieLibrary(await SharedPreferences.getInstance());
    messenger.setMockMethodCallHandler(mediaChannel, (_) async => null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => directory.path,
    );
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(mediaChannel, null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    library.dispose();
    await directory.delete(recursive: true);
  });

  test('Thumbnail platform failures leave downloads usable', () async {
    messenger.setMockMethodCallHandler(
      mediaChannel,
      (_) async => throw PlatformException(code: 'THUMBNAIL_FAILED'),
    );
    expect(await extractThumbnail('/missing.mp4'), isNull);
    messenger.setMockMethodCallHandler(mediaChannel, null);
    expect(await extractThumbnail('/missing.mp4'), isNull);
  });

  test(
    'Thumbnail extraction never starts while the app is backgrounded',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(mediaChannel, (_) async {
        calls++;
        return null;
      });
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      try {
        expect(await extractThumbnail('/video.mp4'), isNull);
        expect(calls, 0);
      } finally {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
    },
  );

  test('Backfill creates and persists a missing thumbnail once', () async {
    final video = await File('${directory.path}/video.mp4')
        .writeAsBytes([1, 2, 3]);
    final preview = File('${video.path}.preview.jpg');
    var calls = 0;
    messenger.setMockMethodCallHandler(mediaChannel, (call) async {
      expect(call.method, 'thumbnail');
      expect(call.arguments, video.path);
      calls++;
      await preview.writeAsBytes([4, 5]);
      return preview.path;
    });
    await library.addDownload(
      SavedDownload(title, 1, 1, '360', video.path, null),
    );
    await library.backfillThumbnails();
    expect(library.downloads.values.single.thumbnailPath, preview.path);
    expect(
      MovieLibrary(library.prefs).downloads.values.single.thumbnailPath,
      preview.path,
    );
    await library.backfillThumbnails();
    expect(calls, 1);
  });

  test('Backfill skips missing videos', () async {
    var called = false;
    messenger.setMockMethodCallHandler(mediaChannel, (_) async {
      called = true;
      return null;
    });
    await library.addDownload(
      SavedDownload(title, 1, 1, '360', '${directory.path}/missing.mp4', null),
    );
    await library.backfillThumbnails();
    expect(called, isFalse);
    expect(library.downloads, hasLength(1));
  });

  test(
    'Deleting a download removes its video, subtitles, and thumbnail',
    () async {
      final video = await File('${directory.path}/video.mp4').writeAsBytes([1]);
      final captions = await File('${video.path}.srt').writeAsString('caption');
      final preview = await File('${video.path}.preview.jpg').writeAsBytes([2]);
      final saved = SavedDownload(
        title,
        1,
        2,
        '360',
        video.path,
        captions.path,
        thumbnailPath: preview.path,
      );
      await library.addDownload(saved);
      await library.removeDownload(saved);
      expect(await video.exists(), isFalse);
      expect(await captions.exists(), isFalse);
      expect(await preview.exists(), isFalse);
      expect(MovieLibrary(library.prefs).downloads, isEmpty);
    },
  );

  test('Shared folder names follow movie-box/<name>/<episode>/', () {
    expect(sharedRelativePath(title, 1, 2), 'movie-box/QA series/S01E02');
    expect(sharedFileName(title, 1, 2), 'QA series S01E02.mp4');
    expect(sharedSubtitleFileName(title, 1, 2), 'QA series S01E02.srt');
    expect(sharedRelativePath(title, 0, 0), 'movie-box/QA series');
    expect(sharedFileName(title, 0, 0), 'QA series.mp4');
  });

  test('Shared folder names drop characters Android cannot store', () {
    final messy = MovieTitle.fromJson({
      'id': 'qa',
      'detail_path': 'messy',
      'kind': 'series',
      'title': 'Spaced: Out / Season 2\\ ',
      'has_resource': true,
    });
    expect(sharedRelativePath(messy, 1, 3), 'movie-box/Spaced Out Season 2/S01E03');
  });

  test('Deleting a download removes its public Downloads copy', () async {
    final video = await File('${directory.path}/video.mp4').writeAsBytes([1]);
    final deleted = <String>[];
    messenger.setMockMethodCallHandler(mediaChannel, (call) async {
      if (call.method == 'deleteSharedFile') deleted.add('${call.arguments}');
      return null;
    });
    final saved = SavedDownload(
      title,
      1,
      2,
      '360',
      video.path,
      null,
      sharedPath: 'content://media/external/downloads/7',
    );
    await library.addDownload(saved);
    await library.removeDownload(saved);
    expect(deleted, ['content://media/external/downloads/7']);
    expect(await video.exists(), isFalse);
  });

  test('Deleting a download removes its exported file path copy', () async {
    final video = await File('${directory.path}/video.mp4').writeAsBytes([1]);
    final exported = await File('${directory.path}/exported.mp4')
        .writeAsBytes([2]);
    final saved = SavedDownload(
      title,
      1,
      2,
      '360',
      video.path,
      null,
      sharedPath: exported.path,
    );
    await library.addDownload(saved);
    await library.removeDownload(saved);
    expect(await exported.exists(), isFalse);
  });

  test(
    'Backfill cannot resurrect a download deleted during extraction',
    () async {
      final video = await File('${directory.path}/video.mp4').writeAsBytes([1]);
      final saved = SavedDownload(title, 1, 1, '360', video.path, null);
      await library.addDownload(saved);
      final started = Completer<void>();
      final extracted = Completer<String>();
      messenger.setMockMethodCallHandler(mediaChannel, (_) {
        started.complete();
        return extracted.future;
      });
      final pending = library.backfillThumbnails();
      await started.future;
      await library.removeDownload(saved);
      extracted.complete('${video.path}.preview.jpg');
      await pending;
      expect(library.downloads, isEmpty);
    },
  );

  test(
    'Thumbnail backfill preserves captions finalized during extraction',
    () async {
      final video = await File('${directory.path}/video.mp4').writeAsBytes([1]);
      final preview = await File('${video.path}.preview.jpg').writeAsBytes([2]);
      final started = Completer<void>();
      final extracted = Completer<String>();
      messenger.setMockMethodCallHandler(mediaChannel, (_) {
        started.complete();
        return extracted.future;
      });
      await library.addDownload(
        SavedDownload(title, 1, 1, '360', video.path, null),
      );
      final pending = library.backfillThumbnails();
      await started.future;
      await library.addDownload(
        SavedDownload(
          title,
          1,
          1,
          '360',
          video.path,
          '${video.path}.srt',
          thumbnailPath: preview.path,
        ),
      );
      extracted.complete(preview.path);
      await pending;
      expect(library.downloads.values.single.subtitlePath, '${video.path}.srt');
      expect(await preview.exists(), isTrue);
    },
  );

  test('Continue Watching groups each series and survives restart', () async {
    await library.record(WatchEntry(title, 1, 1, 30, 300));
    await library.record(WatchEntry(title, 1, 2, 40, 300));
    await library.record(WatchEntry(title, 1, 1, 50, 300));
    final restored = MovieLibrary(library.prefs);
    final latest = latestWatchEntries(restored.history.values);
    expect(latest, hasLength(1));
    expect(latest.single.episode, 1);
    expect(latest.single.positionSeconds, 50);
    expect(restored.history, hasLength(2));
  });
}

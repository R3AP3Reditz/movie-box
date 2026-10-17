import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as native;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movie_box_app/api.dart';
import 'package:movie_box_app/download_backend.dart';
import 'package:movie_box_app/download_probe.dart';
import 'package:movie_box_app/library.dart';
import 'package:movie_box_app/model.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeDownloadBackend implements DownloadBackend {
  void Function(native.TaskUpdate)? listener;
  final enqueued = <native.DownloadTask>[];
  final cancelled = <String>[];
  final paused = <String>[];
  final resumed = <String>[];
  final database = <String, native.TaskRecord>{};
  final running = <String, native.Task>{};
  Future<void> Function(native.DownloadTask)? beforeEnqueue;
  bool acceptEnqueue = true;
  bool acceptResume = true;
  int initializations = 0;
  int notificationRequests = 0;
  native.TaskStatusUpdate? restoredUpdate;
  DownloadMetadata metadata = const DownloadMetadata(4, etag: '"fixture"');
  Future<DownloadMetadata> Function(String, Map<String, String>)? onProbe;
  bool allowNotifications = true;

  @override
  Future<DownloadMetadata> probe(
    String url,
    Map<String, String> headers,
  ) async => onProbe == null ? metadata : await onProbe!(url, headers);

  @override
  Future<void> initialize(void Function(native.TaskUpdate) onUpdate) async {
    listener = onUpdate;
    initializations++;
    if (restoredUpdate != null) onUpdate(restoredUpdate!);
  }

  @override
  Future<void> reconcile() async {}
  @override
  Future<List<native.TaskRecord>> records() async => database.values.toList();
  @override
  Future<List<native.Task>> pending() async => running.values.toList();
  @override
  Future<bool> enqueue(native.DownloadTask task) async {
    await beforeEnqueue?.call(task);
    if (!acceptEnqueue) return false;
    enqueued.add(task);
    running[task.taskId] = task;
    status(task, native.TaskStatus.enqueued);
    return true;
  }

  void status(
    native.Task task,
    native.TaskStatus status, {
    native.TaskException? error,
  }) {
    final previous = database[task.taskId];
    database[task.taskId] = native.TaskRecord(
      task,
      status,
      previous?.progress ?? 0,
      previous?.expectedFileSize ?? -1,
      error,
    );
    if (status.isFinalState) running.remove(task.taskId);
    listener?.call(native.TaskStatusUpdate(task, status, error));
  }

  void progress(native.Task task, double progress, int size) {
    database[task.taskId] = native.TaskRecord(
      task,
      database[task.taskId]?.status ?? native.TaskStatus.running,
      progress,
      size,
    );
    listener?.call(native.TaskProgressUpdate(task, progress, size));
  }

  @override
  Future<bool> cancel(String id) async {
    cancelled.add(id);
    running.remove(id);
    return true;
  }

  @override
  Future<bool> pause(native.DownloadTask task) async {
    paused.add(task.taskId);
    status(task, native.TaskStatus.paused);
    return true;
  }

  @override
  Future<bool> resume(native.DownloadTask task) async {
    resumed.add(task.taskId);
    if (acceptResume) status(task, native.TaskStatus.enqueued);
    return acceptResume;
  }

  @override
  Future<void> requestNotifications() async {
    notificationRequests++;
    if (!allowNotifications) {
      throw ApiException(
        'Allow notifications in Android Settings to run background downloads.',
      );
    }
  }

  @override
  void dispose() => listener = null;
}

class SnapshotApi extends MovieApi {
  final MovieStream stream;
  final Future<void>? wait;
  bool closed = false;
  SnapshotApi(this.stream, {this.wait})
    : super(baseUrl: 'https://snapshot.test');
  @override
  Future<MoviePlayback> playback(String path, int season, int episode) async {
    await wait;
    return MoviePlayback.fromJson({
      'streams': [
        {
          'id': stream.id,
          'format': stream.format,
          'resolutions': stream.resolution,
          'url': stream.url,
        },
      ],
    });
  }

  @override
  Future<List<MovieCaption>> captions(
    String path,
    String streamId,
    int season,
    int episode,
  ) async => [
    MovieCaption.fromJson({
      'label': 'English',
      'language': 'en',
      'url': 'https://fresh.test/captions',
    }),
  ];
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferences prefs;
  late FakeDownloadBackend backend;
  late MovieLibrary library;
  late MovieApi api;
  final title = MovieTitle.fromJson({
    'id': 'series',
    'detail_path': '../unsafe/title',
    'kind': 'series',
    'title': 'A series',
    'poster_url': 'https://poster.test/p.jpg',
    'has_resource': true,
  });
  final stream = MovieStream.fromJson({
    'id': '360',
    'format': 'MP4',
    'resolutions': '360',
    'url': 'https://video.test/old',
    'size_bytes': 99999999,
    'request_headers': {'Referer': 'https://source.test'},
  });
  final fresh = MovieStream.fromJson({
    'id': '360',
    'format': 'MP4',
    'resolutions': '360',
    'url': 'https://video.test/fresh',
  });
  final caption = MovieCaption.fromJson({
    'label': 'English',
    'language': 'en',
    'url': 'https://caption.test/old',
  });

  MovieLibrary createLibrary({MovieApi Function(String, String)? apiFactory}) =>
      MovieLibrary(
        prefs,
        downloadBackend: backend,
        downloadsDirectory: () async => directory,
        downloadApiFactory: apiFactory ?? (_, _) => SnapshotApi(fresh),
      );

  Future<DownloadTask> start({MovieCaption? subtitle}) async {
    final task = library.taskFor(title, 1, 2);
    expect(
      await task.start(api, library, title, 1, 2, stream, subtitle),
      isNull,
    );
    await library.initializeDownloads();
    return task;
  }

  Future<void> complete(native.DownloadTask task, {int length = 4}) async {
    final file = File(await task.filePath());
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(length, 7));
    backend.status(task, native.TaskStatus.complete);
    await library.initializeDownloads();
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('moviebox-native-test-');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    backend = FakeDownloadBackend();
    library = createLibrary();
    api = MovieApi(
      baseUrl: 'https://original-api.test',
      token: 'snapshot-token',
    );
  });

  tearDown(() async {
    library.dispose();
    api.close();
    await directory.delete(recursive: true);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.linux]) {
    test('${platform.name} pending final-copy files are not finalized', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var task = await start();
      final video = backend.enqueued.single;
      backend.status(video, native.TaskStatus.running);
      final file = File(await video.filePath());
      for (final length in [2, 4]) {
        await file.writeAsBytes(List.filled(length, 7));
        await library.initializeDownloads();
        expect(task.statusLabel, 'Downloading');
        expect(task.error, isNull);
        expect(library.downloads, isEmpty);
        expect(backend.enqueued, hasLength(1));
      }
      library.dispose();
      library = createLibrary();
      task = library.taskFor(title, 1, 2);
      await library.initializeDownloads();
      expect(task.complete, isFalse);
      expect(library.downloads, isEmpty);
      backend.running.remove(video.taskId);
      await library.initializeDownloads();
      expect(task.complete, isTrue);
      expect(library.downloads.values.single.path, file.path);
      expect(backend.enqueued, hasLength(1));
    });

    test('${platform.name} selects the expected default download storage', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return '${directory.path}/${call.method}';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      library.dispose();
      library = MovieLibrary(prefs, downloadBackend: backend);
      await start();
      final method = platform == TargetPlatform.linux
          ? 'getApplicationSupportDirectory'
          : 'getApplicationDocumentsDirectory';
      expect(calls, [method]);
      expect(
        await backend.enqueued.single.filePath(),
        startsWith('${directory.path}/$method/downloads/'),
      );
    });

    test('${platform.name} honors an injected download directory', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        throw PlatformException(code: 'UNEXPECTED_PATH_LOOKUP');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await start();
      expect(calls, 0);
      expect(
        await backend.enqueued.single.filePath(),
        startsWith('${directory.path}/downloads/'),
      );
    });

    test('${platform.name} uses only supported thumbnail channels', () async {
      debugDefaultTargetPlatformOverride = platform;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var calls = 0;
      messenger.setMockMethodCallHandler(mediaChannel, (call) async {
        expect(call.method, 'thumbnail');
        calls++;
        return '${call.arguments}.preview.jpg';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(mediaChannel, null));
      final task = await start();
      final video = backend.enqueued.single;
      await complete(video);
      await library.backfillThumbnails();
      expect(task.complete, isTrue);
      if (platform == TargetPlatform.linux) {
        expect(calls, 0);
        expect(library.downloads.values.single.thumbnailPath, isNull);
      } else {
        expect(calls, greaterThan(0));
        expect(
          library.downloads.values.single.thumbnailPath,
          '${await video.filePath()}.preview.jpg',
        );
      }
    });
  }

  test('Pending caption files are not attached before completion', () async {
    final task = await start(subtitle: caption);
    final video = backend.enqueued.first;
    final subtitle = backend.enqueued.last;
    await File(await subtitle.filePath()).writeAsString('partial caption');
    await complete(video);
    await library.initializeDownloads();
    expect(task.complete, isTrue);
    expect(library.downloads.values.single.subtitlePath, isNull);
    expect(backend.enqueued, hasLength(2));
    await complete(subtitle);
    expect(library.downloads.values.single.subtitlePath, await subtitle.filePath());
  });

  test('Interrupted final-copy files fail validation after the worker exits', () async {
    await start();
    final video = backend.enqueued.single;
    await File(await video.filePath()).writeAsBytes([1, 2]);
    backend.running.clear();
    library.dispose();
    library = createLibrary();
    await library.initializeDownloads();
    expect(library.downloads, isEmpty);
    expect(library.taskFor(title, 1, 2).error, contains('incomplete'));
    expect(backend.enqueued, hasLength(1));
  });

  test(
    'Shared episode task persists metadata before enqueue and returns queued',
    () async {
      backend.beforeEnqueue = (nativeTask) async {
        final journal = jsonDecode(prefs.getString('download_jobs_v1')!);
        expect(journal['tasks'].single['video']['taskId'], nativeTask.taskId);
        expect(journal['tasks'].single['title']['title'], title.title);
        expect(journal['tasks'].single['metadata']['length'], 4);
      };
      final task = await start();
      expect(identical(task, library.taskFor(title, 1, 2)), isTrue);
      expect(library.downloadTasks[viewingKey(title.path, 1, 2)], same(task));
      expect(task.active, isTrue);
      expect(task.statusLabel, 'Queued');
      expect(library.downloads, isEmpty);
      expect(backend.enqueued, hasLength(1));
      expect(backend.enqueued.single.allowPause, isTrue);
      expect(backend.enqueued.single.updates, native.Updates.statusAndProgress);
      expect(backend.enqueued.single.headers['Accept-Encoding'], 'identity');
      expect(
        await backend.enqueued.single.filePath(),
        startsWith('${directory.path}/downloads/'),
      );
      expect(backend.enqueued.single.directory, isNot(contains('unsafe')));
      expect(task.total, 4);
      expect(backend.enqueued.single.headers['Known-Content-Length'], '4');
      expect(backend.enqueued.single.headers['If-Match'], '"fixture"');
    },
  );

  test(
    'Concurrent starts and repeated initialization never duplicate the episode',
    () async {
      final task = library.taskFor(title, 1, 2);
      await Future.wait([
        task.start(api, library, title, 1, 2, stream, null),
        task.start(api, library, title, 1, 2, stream, null),
      ]);
      await Future.wait([
        library.initializeDownloads(),
        library.initializeDownloads(),
      ]);
      expect(backend.enqueued, hasLength(1));
      expect(backend.initializations, 1);
    },
  );

  test(
    'Progress uses authoritative metadata, never provider estimates',
    () async {
      backend.metadata = const DownloadMetadata(400);
      final task = await start();
      backend.progress(backend.enqueued.single, .25, 400);
      await library.initializeDownloads();
      expect(task.received, 100);
      expect(task.total, 400);
      backend.progress(backend.enqueued.single, -1, -1);
      await library.initializeDownloads();
      expect(task.received, 100);
    },
  );

  test('Pausing and resuming delegate to the same native generation', () async {
    final task = await start();
    final id = backend.enqueued.single.taskId;
    await task.pause();
    await library.initializeDownloads();
    expect(task.paused, isTrue);
    expect(task.active, isTrue);
    await task.resume();
    await library.initializeDownloads();
    expect(backend.paused, [id]);
    expect(backend.resumed, [id]);
    expect(backend.enqueued, hasLength(1));
  });

  test('Missing native resume data restarts at a fresh URL and path', () async {
    final task = await start();
    final old = backend.enqueued.single;
    await task.pause();
    await library.initializeDownloads();
    backend.acceptResume = false;
    await task.resume();
    expect(backend.enqueued, hasLength(2));
    expect(backend.enqueued.last.url, fresh.url);
    expect(backend.enqueued.last.directory, isNot(old.directory));
    expect(backend.cancelled, contains(old.taskId));
  });

  test(
    'Completion is idempotent and captions can arrive after the video',
    () async {
      final task = await start(subtitle: caption);
      final video = backend.enqueued.first;
      final subtitle = backend.enqueued.last;
      await complete(video);
      expect(task.complete, isTrue);
      expect(library.downloads.values.single.subtitlePath, isNull);
      await complete(subtitle);
      backend.status(video, native.TaskStatus.complete);
      await library.initializeDownloads();
      expect(library.downloads, hasLength(1));
      expect(
        library.downloads.values.single.subtitlePath,
        await subtitle.filePath(),
      );
      expect(library.downloads.values.single.title.poster, title.poster);
      expect(task.received, 4);
      expect(task.total, 4);
    },
  );

  test(
    'Process recreation reconciles completed native records and captions',
    () async {
      await start(subtitle: caption);
      library.dispose();
      for (final nativeTask in backend.enqueued) {
        await File(await nativeTask.filePath()).writeAsBytes([1, 2, 3, 4]);
        backend.status(nativeTask, native.TaskStatus.complete);
      }
      library = createLibrary();
      await library.initializeDownloads();
      expect(library.downloads, hasLength(1));
      expect(library.downloads.values.single.subtitlePath, isNotNull);
      expect(library.taskFor(title, 1, 2).complete, isTrue);
      expect(backend.enqueued, hasLength(2));
    },
  );

  test('Dispose never cancels platform work and active work is adopted after restart', () async {
    await start();
    library.dispose();
    expect(backend.cancelled, isEmpty);
    library = createLibrary();
    await library.initializeDownloads();
    expect(library.taskFor(title, 1, 2).active, isTrue);
    expect(backend.enqueued, hasLength(1));
  });

  test(
    'Killed or never-enqueued work is recovered with a distinct generation',
    () async {
      await start();
      final old = backend.enqueued.single;
      backend.running.clear();
      library.dispose();
      library = createLibrary();
      await library.initializeDownloads();
      expect(backend.enqueued, hasLength(2));
      expect(backend.enqueued.last.directory, isNot(old.directory));
      expect(backend.cancelled, contains(old.taskId));
    },
  );

  test(
    'Cancel tombstone survives restart and rejects late completion',
    () async {
      final task = await start(subtitle: caption);
      final video = backend.enqueued.first;
      await task.cancel();
      await File(await video.filePath()).writeAsBytes([1]);
      backend.status(video, native.TaskStatus.complete);
      await library.initializeDownloads();
      expect(library.downloads, isEmpty);
      expect(await File(await video.filePath()).exists(), isFalse);
      library.dispose();
      library = createLibrary();
      await library.initializeDownloads();
      expect(library.taskFor(title, 1, 2).cancelled, isTrue);
      expect(library.downloads, isEmpty);
      expect(backend.enqueued, hasLength(2));
    },
  );

  test('Cancel while enqueue is awaiting native acknowledgement does not resurrect', () async {
    final reached = Completer<void>();
    final release = Completer<void>();
    backend.beforeEnqueue = (_) async {
      reached.complete();
      await release.future;
    };
    final task = library.taskFor(title, 1, 2);
    final starting = task.start(api, library, title, 1, 2, stream, null);
    await reached.future;
    final cancelling = task.cancel();
    release.complete();
    await Future.wait([starting, cancelling]);
    await library.initializeDownloads();
    expect(task.cancelled, isTrue);
    expect(backend.running, isEmpty);
    expect(library.downloads, isEmpty);
  });

  test('Expired links use an independently owned API snapshot and only refresh once', () async {
    final snapshots = <SnapshotApi>[];
    library.dispose();
    library = createLibrary(
      apiFactory: (server, token) {
        expect(server, 'https://original-api.test');
        expect(token, 'snapshot-token');
        final snapshot = SnapshotApi(fresh);
        snapshots.add(snapshot);
        return snapshot;
      },
    );
    final task = await start();
    api.close();
    backend.status(
      backend.enqueued.single,
      native.TaskStatus.failed,
      error: native.TaskHttpException('Expired', 403),
    );
    await library.initializeDownloads();
    expect(backend.enqueued.last.url, fresh.url);
    expect(snapshots.single.closed, isTrue);
    backend.status(
      backend.enqueued.last,
      native.TaskStatus.failed,
      error: native.TaskHttpException('Expired again', 401),
    );
    await library.initializeDownloads();
    expect(snapshots, hasLength(1));
    expect(task.active, isFalse);
    expect(task.error, contains('401'));
  });

  test('Old generation completion after retry cannot replace or delete the new file', () async {
    final task = await start();
    final old = backend.enqueued.single;
    backend.status(old, native.TaskStatus.failed);
    await library.initializeDownloads();
    await task.retry();
    final replacement = backend.enqueued.last;
    await complete(replacement);
    await File(await old.filePath()).writeAsBytes([9]);
    backend.status(old, native.TaskStatus.complete);
    await library.initializeDownloads();
    expect(library.downloads.values.single.path, await replacement.filePath());
    expect(await File(library.downloads.values.single.path).exists(), isTrue);
    expect(await File(await old.filePath()).exists(), isFalse);
  });

  test(
    'Deleting a completed task cannot be undone by native DB replay',
    () async {
      await start();
      final video = backend.enqueued.single;
      await complete(video);
      await library.removeDownload(library.downloads.values.single);
      await library.initializeDownloads();
      library.dispose();
      library = createLibrary();
      await library.initializeDownloads();
      expect(library.downloads, isEmpty);
      expect(library.taskFor(title, 1, 2).cancelled, isTrue);
      expect(backend.enqueued, hasLength(1));
    },
  );

  test('A truncated completed file is never advertised as saved', () async {
    final task = await start();
    final video = backend.enqueued.single;
    backend.progress(video, .5, 100);
    await complete(video, length: 50);
    expect(library.downloads, isEmpty);
    expect(task.active, isFalse);
    expect(task.error, contains('incomplete'));
  });

  test(
    'Missing completed files are removed from the saved library on restart',
    () async {
      await start();
      final video = backend.enqueued.single;
      await complete(video);
      await File(await video.filePath()).delete();
      library.dispose();
      library = createLibrary();
      await library.initializeDownloads();
      expect(library.downloads, isEmpty);
      expect(library.taskFor(title, 1, 2).error, contains('missing'));
    },
  );

  test(
    'Caption cancellation is terminal and never restarts on reconciliation',
    () async {
      await start(subtitle: caption);
      final video = backend.enqueued.first;
      final subtitle = backend.enqueued.last;
      backend.status(subtitle, native.TaskStatus.canceled);
      await library.initializeDownloads();
      await complete(video);
      await library.initializeDownloads();
      expect(backend.enqueued, hasLength(2));
      expect(library.downloads.values.single.subtitlePath, isNull);
    },
  );

  test(
    'Expired captions refresh independently without restarting saved video',
    () async {
      await start(subtitle: caption);
      final video = backend.enqueued.first;
      final subtitle = backend.enqueued.last;
      await complete(video);
      backend.status(
        subtitle,
        native.TaskStatus.failed,
        error: native.TaskHttpException('Expired caption', 403),
      );
      await library.initializeDownloads();
      expect(backend.enqueued, hasLength(3));
      expect(backend.enqueued.last.url, 'https://fresh.test/captions');
      expect(library.downloads.values.single.path, await video.filePath());
      await complete(backend.enqueued.last);
      expect(
        library.downloads.values.single.subtitlePath,
        await backend.enqueued.last.filePath(),
      );
    },
  );

  test('Interrupted refresh metadata recovers rather than remaining active forever', () async {
    await start();
    final old = backend.enqueued.single;
    library.dispose();
    final journal = jsonDecode(prefs.getString('download_jobs_v1')!);
    journal['tasks'].single['state'] = 'refreshing';
    journal['tombstones'][old.taskId] = await old.filePath();
    await prefs.setString('download_jobs_v1', jsonEncode(journal));
    library = createLibrary();
    await library.initializeDownloads();
    expect(backend.enqueued, hasLength(2));
    expect(backend.enqueued.last.url, fresh.url);
    expect(backend.enqueued.last.directory, isNot(old.directory));
  });

  test(
    'Persisted tombstone removes a saved entry after interrupted deletion',
    () async {
      await start();
      final video = backend.enqueued.single;
      await complete(video);
      library.dispose();
      final journal = jsonDecode(prefs.getString('download_jobs_v1')!);
      journal['tasks'].single['state'] = 'cancelled';
      journal['tombstones'][video.taskId] = await video.filePath();
      await prefs.setString('download_jobs_v1', jsonEncode(journal));
      library = createLibrary();
      await library.initializeDownloads();
      expect(library.downloads, isEmpty);
      expect(await File(await video.filePath()).exists(), isFalse);
    },
  );

  test('Cancellation persists even while a link refresh is blocked', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    library.dispose();
    library = createLibrary(
      apiFactory: (_, _) {
        entered.complete();
        return SnapshotApi(fresh, wait: release.future);
      },
    );
    final task = await start();
    final old = backend.enqueued.single;
    backend.status(
      old,
      native.TaskStatus.failed,
      error: native.TaskHttpException('Expired', 403),
    );
    await entered.future;
    final cancelled = task.cancel();
    await Future<void>.delayed(Duration.zero);
    final journal = jsonDecode(prefs.getString('download_jobs_v1')!);
    expect(journal['tasks'].single['state'], 'cancelled');
    expect(journal['tombstones'], contains(old.taskId));
    release.complete();
    await cancelled;
    await library.initializeDownloads();
    expect(backend.enqueued, hasLength(1));
    expect(task.cancelled, isTrue);
  });

  test('Stale saved-entry deletion cannot delete a new generation', () async {
    final task = await start();
    await complete(backend.enqueued.single);
    final old = library.downloads.values.single;
    await library.removeDownload(old);
    await task.retry();
    await complete(backend.enqueued.last);
    final current = library.downloads.values.single;
    await library.removeDownload(old);
    expect(library.downloads.values.single.path, current.path);
    expect(await File(current.path).exists(), isTrue);
  });

  test(
    'Undelivered notification cancellation beats stale native DB recovery',
    () async {
      await start();
      final video = backend.enqueued.single;
      library.dispose();
      backend.running.clear();
      backend.restoredUpdate = native.TaskStatusUpdate(
        video,
        native.TaskStatus.canceled,
      );
      library = createLibrary();
      await library.initializeDownloads();
      await library.initializeDownloads();
      expect(library.taskFor(title, 1, 2).cancelled, isTrue);
      expect(backend.enqueued, hasLength(1));
      expect(library.downloads, isEmpty);
    },
  );

  test(
    'Crash before progress rejects a mismatched nonempty completed file',
    () async {
      await start();
      final video = backend.enqueued.single;
      library.dispose();
      await File(await video.filePath()).writeAsBytes([1, 2]);
      backend.status(video, native.TaskStatus.complete);
      library = createLibrary();
      expect(library.taskFor(title, 1, 2).total, 4);
      await library.initializeDownloads();
      expect(library.downloads, isEmpty);
      expect(library.taskFor(title, 1, 2).error, contains('incomplete'));
    },
  );

  test(
    'Inconsistent native progress never replaces authoritative length',
    () async {
      final task = await start();
      backend.progress(backend.enqueued.single, .5, 800);
      await library.initializeDownloads();
      expect(task.total, 4);
      expect(task.received, 0);
      await complete(backend.enqueued.single);
      expect(library.downloads, hasLength(1));
    },
  );

  test(
    'Preflight 403 refreshes once and persists refreshed metadata',
    () async {
      var probes = 0;
      backend.onProbe = (url, headers) async {
        probes++;
        if (probes == 1) throw DownloadProbeHttpException(403);
        expect(url, fresh.url);
        return const DownloadMetadata(4, etag: '"fresh"');
      };
      await start();
      expect(probes, 2);
      expect(backend.enqueued.single.headers['If-Match'], '"fresh"');
    },
  );

  test('Repeated preflight authorization failure and metadata timeout are retriable', () async {
    var probes = 0;
    backend.onProbe = (_, _) async {
      probes++;
      throw DownloadProbeHttpException(401);
    };
    final task = library.taskFor(title, 1, 2);
    await expectLater(
      task.start(api, library, title, 1, 2, stream, null),
      throwsA(isA<ApiException>()),
    );
    expect(probes, 2);
    expect(task.active, isFalse);
    expect(backend.enqueued, isEmpty);
    backend.onProbe = (_, _) async =>
        throw ApiException('Download metadata timed out. Retry to try again.');
    await expectLater(task.retry(), throwsA(isA<ApiException>()));
    expect(task.active, isFalse);
    backend.onProbe = null;
    await task.retry();
    expect(backend.enqueued, hasLength(1));
  });

  test(
    'Permission gate covers start retry resume and recovered reenqueue',
    () async {
      backend.allowNotifications = false;
      final task = library.taskFor(title, 1, 2);
      await expectLater(
        task.start(api, library, title, 1, 2, stream, null),
        throwsA(isA<ApiException>()),
      );
      expect(backend.enqueued, isEmpty);
      await expectLater(task.retry(), throwsA(isA<ApiException>()));
      backend.allowNotifications = true;
      await task.retry();
      await task.pause();
      await library.initializeDownloads();
      backend.allowNotifications = false;
      await expectLater(task.resume(), throwsA(isA<ApiException>()));
      expect(backend.resumed, isEmpty);
      expect(task.paused, isTrue);
      backend.allowNotifications = true;
      await task.resume();
      await library.initializeDownloads();
      library.dispose();
      backend.running.clear();
      backend.allowNotifications = false;
      library = createLibrary();
      await expectLater(
        library.initializeDownloads(),
        throwsA(isA<ApiException>()),
      );
      expect(backend.enqueued, hasLength(1));
      expect(library.taskFor(title, 1, 2).active, isFalse);
    },
  );

  test('Enqueue rejection is a persisted actionable failure', () async {
    backend.acceptEnqueue = false;
    final task = library.taskFor(title, 1, 2);
    await expectLater(
      task.start(api, library, title, 1, 2, stream, null),
      throwsA(isA<ApiException>()),
    );
    expect(task.active, isFalse);
    expect(task.error, contains('enqueue'));
    library.dispose();
    library = createLibrary();
    expect(library.taskFor(title, 1, 2).statusLabel, 'Download failed');
  });

  test(
    'Separate episodes transfer concurrently and cancel independently',
    () async {
      final first = library.taskFor(title, 1, 1);
      final second = library.taskFor(title, 1, 2);
      await first.start(api, library, title, 1, 1, stream, null);
      await second.start(api, library, title, 1, 2, stream, null);
      await library.initializeDownloads();
      expect(backend.running, hasLength(2));
      expect(first.active, isTrue);
      expect(second.active, isTrue);
      final secondNative = backend.enqueued.last;
      await first.cancel();
      expect(backend.cancelled, isNot(contains(secondNative.taskId)));
      expect(second.active, isTrue);
      await complete(secondNative);
      expect(library.downloads.keys, [second.key]);
    },
  );
}

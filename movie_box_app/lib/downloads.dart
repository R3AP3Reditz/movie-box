part of 'library.dart';

class DownloadTask extends ChangeNotifier {
  final _DownloadCoordinator _owner;
  final MovieTitle title;
  final int season;
  final int episode;
  String _state = 'idle';
  String? error;
  int received = 0;
  int? total;
  DownloadMetadata? _metadata;
  String? _server;
  String? _token;
  MovieStream? _stream;
  MovieCaption? _caption;
  native.DownloadTask? _video;
  native.DownloadTask? _subtitle;
  String _captionState = 'none';
  int _refreshes = 0;
  int _captionRefreshes = 0;
  bool _starting = false;
  bool _disposed = false;
  DateTime _lastProgressSave = DateTime.fromMillisecondsSinceEpoch(0);

  DownloadTask._(this._owner, this.title, this.season, this.episode);

  String get key => viewingKey(title.path, season, episode);
  bool get active =>
      _starting ||
      const {
        'preparing',
        'queued',
        'running',
        'paused',
        'refreshing',
        'waitingToRetry',
      }.contains(_state);
  bool get cancelled => _state == 'cancelled';
  bool get paused => _state == 'paused';
  bool get complete => _state == 'complete';
  String get statusLabel => switch (_state) {
    'preparing' => 'Preparing',
    'queued' => 'Queued',
    'running' => 'Downloading',
    'paused' => 'Paused',
    'refreshing' => 'Refreshing download link',
    'waitingToRetry' => 'Waiting to retry',
    'complete' =>
      _captionState == 'failed'
          ? 'Downloaded • captions unavailable'
          : 'Downloaded',
    'cancelled' => 'Cancelled',
    'failed' => 'Download failed',
    _ => 'Ready to download',
  };
  String? get _videoPath => _path(_video);
  // Native root directories omit the leading separator.
  static String? _path(native.DownloadTask? task) => task == null
      ? null
      : '${Platform.isWindows ? '' : '/'}${task.directory}/${task.filename}';

  void _notify() {
    if (!_disposed) notifyListeners();
    _owner.library._notify();
  }

  Future<SavedDownload?> start(
    MovieApi api,
    MovieLibrary library,
    MovieTitle title,
    int season,
    int episode,
    MovieStream stream,
    MovieCaption? caption,
  ) async {
    if (library != _owner.library ||
        viewingKey(title.path, season, episode) != key) {
      throw ArgumentError('Use library.taskFor for the selected episode.');
    }
    if (active) return null;
    if (library.downloads.containsKey(key)) return library.downloads[key];
    _starting = true;
    _state = 'preparing';
    error = null;
    _notify();
    try {
      await _owner.initialize();
      return await _owner.serial(() async {
        if (cancelled) return null;
        _server = api.baseUrl;
        _token = api.token;
        _stream = stream;
        _caption = caption;
        _refreshes = 0;
        _captionRefreshes = 0;
        if (!cancelled) await _owner.replaceGeneration(this);
        return null;
      });
    } catch (failure) {
      if (!cancelled) {
        _state = 'failed';
        error = '$failure';
      }
      rethrow;
    } finally {
      _starting = false;
      _notify();
    }
  }

  Future<void> pause() => _owner.serial(() async {
    final video = _video;
    if (video == null || !active || paused || cancelled) return;
    if (!await _owner.backend.pause(video)) {
      error =
          'This server cannot pause this download. Cancel or let it finish.';
      _notify();
    }
  });

  Future<void> resume() => _owner.serial(() async {
    final video = _video;
    if (video == null || !paused) return;
    try {
      await _owner.backend.requestNotifications();
    } catch (failure) {
      error = '$failure';
      await _owner.save();
      _notify();
      rethrow;
    }
    if (cancelled) return;
    if (_metadata == null) {
      await _owner.replaceGeneration(this, refresh: true);
      return;
    }
    if (await _owner.backend.resume(video)) {
      if (!cancelled) _state = 'queued';
    } else if (!cancelled) {
      // A missing resume file requires a fresh destination, not an append.
      await _owner.replaceGeneration(this, refresh: true);
    }
    await _owner.save();
    _notify();
  });

  Future<void> cancel() {
    // Invalidate immediately, including while enqueue/finalization is awaiting IO.
    _state = 'cancelled';
    _owner.retire(_video);
    _owner.retire(_subtitle);
    _notify();
    final persisted = _owner.save();
    return _owner.serial(() async {
      await persisted;
      await _owner.cleanTombstones();
    });
  }

  Future<void> retry() async {
    if (active || complete || _stream == null) return;
    _starting = true;
    error = null;
    _state = 'refreshing';
    _notify();
    try {
      await _owner.initialize();
      await _owner.serial(() async {
        if (cancelled) return;
        _refreshes = 0;
        _captionRefreshes = 0;
        await _owner.replaceGeneration(this, refresh: true);
      });
    } catch (failure) {
      if (!cancelled) {
        _state = 'failed';
        error = '$failure';
        await _owner.save();
      }
      rethrow;
    } finally {
      _starting = false;
      _notify();
    }
  }

  Map<String, dynamic> _toJson() => {
    'title': title.toJson(),
    'season': season,
    'episode': episode,
    'state': _state,
    'error': error,
    'received': received,
    'total': total,
    'metadata': _metadata?.toJson(),
    'server': _server,
    'token': _token,
    'stream': _stream == null ? null : _streamJson(_stream!),
    'caption': _caption == null ? null : _captionJson(_caption!),
    'video': _video?.toJson(),
    'subtitle': _subtitle?.toJson(),
    'captionState': _captionState,
    'refreshes': _refreshes,
    'captionRefreshes': _captionRefreshes,
  };

  factory DownloadTask._fromJson(
    _DownloadCoordinator owner,
    Map<String, dynamic> json,
  ) {
    final task = DownloadTask._(
      owner,
      MovieTitle.fromJson(json['title'] as Map<String, dynamic>),
      json['season'] as int,
      json['episode'] as int,
    );
    task._state = json['state'] as String? ?? 'failed';
    task.error = json['error'] as String?;
    task.received = json['received'] as int? ?? 0;
    if (json['metadata'] != null) {
      task._metadata = DownloadMetadata.fromJson(json['metadata']);
    }
    task.total = task._metadata?.length ?? json['total'] as int?;
    task._server = json['server'] as String?;
    task._token = json['token'] as String?;
    if (json['stream'] != null) {
      task._stream = MovieStream.fromJson(json['stream']);
    }
    if (json['caption'] != null) {
      task._caption = MovieCaption.fromJson(json['caption']);
    }
    if (json['video'] != null) {
      task._video = native.DownloadTask.fromJson(json['video']);
    }
    if (json['subtitle'] != null) {
      task._subtitle = native.DownloadTask.fromJson(json['subtitle']);
    }
    task._captionState = json['captionState'] as String? ?? 'none';
    task._refreshes = json['refreshes'] as int? ?? 0;
    task._captionRefreshes = json['captionRefreshes'] as int? ?? 0;
    return task;
  }

  @override
  void dispose() {
    _disposed = true;
    // Disposal only detaches listeners; the platform worker owns the transfer.
    super.dispose();
  }
}

Map<String, dynamic> _streamJson(MovieStream stream) => {
  'id': stream.id,
  'format': stream.format,
  'resolutions': stream.resolution,
  'url': stream.url,
  'request_headers': stream.headers,
  'size_bytes': stream.size,
  'vip_locked': stream.locked,
};

Map<String, dynamic> _captionJson(MovieCaption caption) => {
  'label': caption.label,
  'language': caption.language,
  'url': caption.url,
  'request_headers': caption.headers,
};

class _DownloadCoordinator {
  final MovieLibrary library;
  late final DownloadBackend backend =
      library.downloadBackend ?? NativeDownloadBackend();
  final Map<String, DownloadTask> tasks = {};
  final Map<String, String> tombstones = {};
  Future<void>? _tail;
  Future<void>? _initializing;
  bool _initialized = false;
  bool _backendStarted = false;
  bool _disposed = false;

  _DownloadCoordinator(this.library) {
    final raw = library.prefs.getString('download_jobs_v1');
    if (raw == null) return;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    tombstones.addAll(
      Map<String, String>.from(json['tombstones'] as Map? ?? {}),
    );
    for (final item in json['tasks'] as List? ?? []) {
      final task = DownloadTask._fromJson(this, item as Map<String, dynamic>);
      tasks[task.key] = task;
    }
  }

  DownloadTask taskFor(MovieTitle title, int season, int episode) =>
      tasks.putIfAbsent(
        viewingKey(title.path, season, episode),
        () => DownloadTask._(this, title, season, episode),
      );

  Future<T> serial<T>(Future<T> Function() operation) {
    final result = (_tail ?? Future<void>.value()).then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void>? _saveTail;

  Future<void> save() {
    final result = (_saveTail ?? Future<void>.value()).then((_) => _persist());
    _saveTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _persist() async {
    if (!await library.prefs.setString(
      'download_jobs_v1',
      jsonEncode({
        'tasks': tasks.values
            .where((task) => task._stream != null)
            .map((task) => task._toJson())
            .toList(),
        'tombstones': tombstones,
      }),
    )) {
      throw const FileSystemException('Could not persist download queue.');
    }
  }

  Future<void> initialize() {
    if (_disposed) return Future.value();
    return _initializing ??= serial(() async {
      if (!_initialized) {
        _backendStarted = true;
        await backend.initialize(_onUpdate);
        _initialized = true;
      } else {
        await backend.reconcile();
      }
      await cleanTombstones();
      await _reconcile();
    }).whenComplete(() => _initializing = null);
  }

  void _onUpdate(native.TaskUpdate update) {
    if (_disposed) return;
    if (update is native.TaskStatusUpdate &&
        update.status == native.TaskStatus.canceled) {
      final task = _find(update.task.taskId);
      if (task != null && !tombstones.containsKey(update.task.taskId)) {
        if (task._video?.taskId == update.task.taskId && !task.complete) {
          unawaited(
            task.cancel().catchError((Object failure) {
              task.error = '$failure';
              task._notify();
            }),
          );
          return;
        } else if (task._subtitle?.taskId == update.task.taskId &&
            task._captionState != 'complete') {
          retire(task._subtitle);
          task._captionState = 'failed';
          final persisted = save();
          unawaited(
            serial(() async {
              await persisted;
              await cleanTombstones();
              task._notify();
            }).catchError((Object failure) {
              task.error = '$failure';
              task._notify();
            }),
          );
          return;
        }
      }
    }
    unawaited(
      serial(() => _apply(update)).catchError((Object failure) {
        final task = _find(update.task.taskId);
        if (task != null && !task.cancelled) {
          task.error = '$failure';
          task._notify();
        }
      }),
    );
  }

  DownloadTask? _find(String id) {
    for (final task in tasks.values) {
      if (task._video?.taskId == id || task._subtitle?.taskId == id) {
        return task;
      }
    }
    return null;
  }

  void retire(native.DownloadTask? task) {
    if (task != null) tombstones[task.taskId] = DownloadTask._path(task)!;
  }

  Future<void> cleanTombstones() async {
    final paths = tombstones.values.toSet();
    for (final saved in library.downloads.values.toList()) {
      if (paths.contains(saved.path)) {
        library.downloads.remove(saved.key);
        await library._saveDownloads();
        await _deleteFile(saved.subtitlePath);
        await _deleteFile(saved.thumbnailPath);
      }
    }
    for (final entry in tombstones.entries.toList()) {
      await backend.cancel(entry.key);
      await _deleteFile(entry.value);
      await _deleteFile('${entry.value}.preview.jpg');
    }
  }

  bool _current(DownloadTask task, String id) =>
      !task.cancelled &&
      !tombstones.containsKey(id) &&
      (task._video?.taskId == id || task._subtitle?.taskId == id);

  String _id() =>
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32).toRadixString(16)}';

  MovieApi _api(DownloadTask task) =>
      library.downloadApiFactory?.call(
        task._server ?? library.server,
        task._token ?? library.token,
      ) ??
      MovieApi(
        baseUrl: task._server ?? library.server,
        token: task._token ?? library.token,
      );

  Future<void> _refresh(DownloadTask task) async {
    final api = _api(task);
    try {
      final playback = await api.playback(
        task.title.path,
        task.season,
        task.episode,
      );
      task._stream = playback.streams.firstWhere(
        (stream) =>
            stream.format == task._stream!.format &&
            stream.resolution == task._stream!.resolution &&
            !stream.locked,
        orElse: () => throw ApiException(
          'The selected download quality is no longer available.',
        ),
      );
      if (task._caption != null) {
        try {
          final captions = await api.captions(
            task.title.path,
            task._stream!.id,
            task.season,
            task.episode,
          );
          task._caption = captions.firstWhere(
            (caption) =>
                caption.language == task._caption!.language &&
                caption.label == task._caption!.label,
            orElse: () => task._caption!,
          );
        } catch (_) {
          // Caption failure must not prevent a video retry.
        }
      }
    } finally {
      api.close();
    }
  }

  Future<void> replaceGeneration(
    DownloadTask task, {
    bool refresh = false,
  }) async {
    try {
      if (task.cancelled) return;
      await backend.requestNotifications();
      if (task.cancelled) return;
      retire(task._video);
      retire(task._subtitle);
      task._state = refresh ? 'refreshing' : 'preparing';
      await save();
      await cleanTombstones();
      if (refresh) await _refresh(task);
      if (task.cancelled) return;
      final metadata = await _probe(task);
      if (task.cancelled) return;
      task._metadata = metadata;
      task.total = metadata.length;
      final directory =
          await (library.downloadsDirectory?.call() ??
              (isDesktopWindow
                  ? getApplicationSupportDirectory()
                  : getApplicationDocumentsDirectory()));
      if (task.cancelled) return;
      final id = _id();
      final destination = Directory('${directory.path}/downloads/$id');
      await destination.create(recursive: true);
      if (task.cancelled) return;
      task._video = native.DownloadTask(
        taskId: 'moviebox-$id-video',
        url: task._stream!.url,
        headers: {
          ...downloadRequestHeaders(task._stream!.headers),
          'Known-Content-Length': '${metadata.length}',
          if (metadata.etag != null) 'If-Match': metadata.etag!,
        },
        filename: 'video.mp4',
        directory: destination.path,
        baseDirectory: native.BaseDirectory.root,
        group: movieDownloadGroup,
        updates: native.Updates.statusAndProgress,
        allowPause: true,
        retries: 0,
        displayName:
            '${task.title.title} • S${task.season} E${task.episode} • ${task._stream!.resolution}p',
      );
      task._subtitle = task._caption == null
          ? null
          : _subtitleTask(task, destination.path);
      task._captionState = task._subtitle == null ? 'none' : 'queued';
      task._state = 'queued';
      task.received = 0;
      task.total = metadata.length;
      task.error = null;
      await save();
      task._notify();
      final video = task._video!;
      if (!_current(task, video.taskId)) return;
      if (!await backend.enqueue(video)) {
        throw ApiException(
          'The system could not enqueue this download. Retry to try again.',
        );
      }
      if (!_current(task, video.taskId)) {
        await save();
        await cleanTombstones();
        return;
      }
      final subtitle = task._subtitle;
      if (subtitle != null && !await backend.enqueue(subtitle)) {
        task._captionState = 'failed';
        await save();
      }
    } catch (failure) {
      if (!task.cancelled) {
        task._state = 'failed';
        task.error = '$failure';
        await save();
        task._notify();
      }
      rethrow;
    }
  }

  Future<DownloadMetadata> _probe(DownloadTask task) async {
    while (true) {
      try {
        final metadata = await backend.probe(
          task._stream!.url,
          downloadRequestHeaders(task._stream!.headers),
        );
        if (metadata.length <= 0) {
          throw ApiException(
            'This quality has no verifiable download size. Choose another quality.',
          );
        }
        return metadata;
      } on DownloadProbeHttpException catch (failure) {
        if ((failure.statusCode != 401 && failure.statusCode != 403) ||
            task._refreshes >= 1 ||
            task.cancelled) {
          rethrow;
        }
        task._refreshes++;
        await save();
        await _refresh(task);
      }
    }
  }

  native.DownloadTask _subtitleTask(DownloadTask task, String directory) =>
      native.DownloadTask(
        taskId: 'moviebox-${_id()}-caption',
        url: task._caption!.url,
        headers: {...task._caption!.headers, 'Accept-Encoding': 'identity'},
        filename: 'captions-${_id()}.srt',
        directory: directory,
        baseDirectory: native.BaseDirectory.root,
        group: movieDownloadGroup,
        updates: native.Updates.statusAndProgress,
        retries: 0,
        displayName: '${task.title.title} • ${task._caption!.label} captions',
      );

  Future<void> _refreshCaption(DownloadTask task) async {
    await backend.requestNotifications();
    task._captionRefreshes++;
    retire(task._subtitle);
    await save();
    await cleanTombstones();
    await _refresh(task);
    if (task.cancelled) return;
    task._subtitle = _subtitleTask(task, task._video!.directory);
    task._captionState = 'queued';
    await save();
    if (!task.cancelled && !await backend.enqueue(task._subtitle!)) {
      task._captionState = 'failed';
      await save();
    }
  }

  Future<void> _apply(native.TaskUpdate update) async {
    final id = update.task.taskId;
    if (tombstones.containsKey(id)) {
      await backend.cancel(id);
      await _deleteFile(tombstones[id]);
      return;
    }
    final task = _find(id);
    if (task == null || !_current(task, id)) return;
    final isVideo = task._video?.taskId == id;
    if (update is native.TaskProgressUpdate) {
      if (!isVideo || task.complete || update.progress < 0) return;
      final length = task._metadata?.length;
      if (length != null) {
        task.total = length;
        if (!update.hasExpectedFileSize ||
            update.expectedFileSize <= 0 ||
            update.expectedFileSize == length) {
          task.received = (length * update.progress.clamp(0, 1)).round();
        }
      }
      task._notify();
      final now = DateTime.now();
      if (now.difference(task._lastProgressSave).inSeconds >= 1) {
        task._lastProgressSave = now;
        await save();
      }
      return;
    }
    if (update is! native.TaskStatusUpdate) return;
    if (isVideo &&
        task.complete &&
        update.status != native.TaskStatus.complete) {
      return;
    }
    final status = update.status;
    if (!isVideo &&
        task._captionState == 'complete' &&
        status != native.TaskStatus.complete) {
      return;
    }
    if (status == native.TaskStatus.canceled && isVideo) {
      task._state = 'cancelled';
      retire(task._video);
      retire(task._subtitle);
      await save();
      await cleanTombstones();
    } else if (status == native.TaskStatus.canceled) {
      task._captionState = 'failed';
      retire(task._subtitle);
      await save();
      await cleanTombstones();
    } else if (status == native.TaskStatus.complete) {
      if (!isVideo) task._captionState = 'complete';
      if (isVideo || task.complete) await _finalize(task);
    } else if (status == native.TaskStatus.failed ||
        status == native.TaskStatus.notFound) {
      final code =
          update.responseStatusCode ??
          (update.exception?.toJson()['httpResponseCode'] as int?);
      if ((code == 401 || code == 403) &&
          (isVideo ? task._refreshes < 1 : task._captionRefreshes < 1)) {
        if (isVideo) {
          task._refreshes++;
          await replaceGeneration(task, refresh: true);
        } else {
          try {
            await _refreshCaption(task);
          } catch (_) {
            task._captionState = 'failed';
          }
        }
      } else if (isVideo) {
        task._state = 'failed';
        task.error =
            update.exception?.toString() ??
            'Download failed. Retry to try again.';
      } else {
        task._captionState = 'failed';
      }
    } else if (isVideo) {
      task._state = switch (status) {
        native.TaskStatus.enqueued => 'queued',
        native.TaskStatus.running => 'running',
        native.TaskStatus.paused => 'paused',
        native.TaskStatus.waitingToRetry => 'waitingToRetry',
        _ => task._state,
      };
    } else {
      task._captionState = status.name;
    }
    await save();
    task._notify();
  }

  Future<void> _finalize(DownloadTask task) async {
    // Re-finalizing a restored download must not copy it into Downloads again.
    final firstCompletion = !task.complete;
    final video = task._video!;
    final id = video.taskId;
    final file = File(DownloadTask._path(video)!);
    if (!await file.exists()) {
      if (_current(task, id)) {
        task._state = 'failed';
        task.error =
            'The downloaded file is missing. Retry to download it again.';
        await _discardSavedFile(task, file.path);
      }
      return;
    }
    final length = await file.length();
    if (!_current(task, id)) return;
    if (task._metadata == null || length != task._metadata!.length) {
      task._state = 'failed';
      task.error =
          'The downloaded file is incomplete. Retry to download it again.';
      await _discardSavedFile(task, file.path);
      return;
    }
    final captionPath = DownloadTask._path(task._subtitle);
    final hasCaption =
        task._captionState == 'complete' &&
        captionPath != null &&
        await File(captionPath).exists();
    if (!_current(task, id)) return;
    final previous = library.downloads[task.key];
    final saved = SavedDownload(
      task.title,
      task.season,
      task.episode,
      task._stream!.resolution,
      file.path,
      hasCaption ? captionPath : null,
      thumbnailPath: previous?.path == file.path
          ? previous?.thumbnailPath
          : null,
      sharedPath: previous?.path == file.path ? previous?.sharedPath : null,
      sharedSubtitlePath: previous?.path == file.path
          ? previous?.sharedSubtitlePath
          : null,
    );
    // No awaits between the generation check and insertion.
    library.downloads[task.key] = saved;
    await library._saveDownloads();
    if (!_current(task, id)) return;
    task.received = length;
    task.total = length;
    task._state = 'complete';
    task.error = null;
    await save();
    task._notify();
    if (_foreground && saved.thumbnailPath == null && _current(task, id)) {
      final thumbnail = await extractThumbnail(file.path);
      if (thumbnail != null) {
        final current = library.downloads[task.key];
        if (_current(task, id) && current?.path == file.path) {
          await library.addDownload(
            SavedDownload(
              task.title,
              task.season,
              task.episode,
              task._stream!.resolution,
              file.path,
              current!.subtitlePath,
              thumbnailPath: thumbnail,
              sharedPath: current.sharedPath,
              sharedSubtitlePath: current.sharedSubtitlePath,
            ),
          );
        } else {
          await _deleteFile(thumbnail);
        }
      }
    }
    if (firstCompletion && saved.sharedPath == null && _current(task, id)) {
      unawaited(_share(task, file).catchError((Object _) {}));
    }
  }

  /// Copies a finished download into the phone's public Downloads folder.
  /// The app keeps its own copy, so playback and captions are unaffected.
  Future<void> _share(DownloadTask task, File file) async {
    final current = library.downloads[task.key];
    if (current == null || current.path != file.path || current.sharedPath != null) {
      return;
    }
    final captionPath = current.subtitlePath;
    final hasCaption =
        captionPath != null && await File(captionPath).exists();
    final shared = await exportToDownloads(
      path: file.path,
      relativePath: sharedRelativePath(task.title, task.season, task.episode),
      fileName: sharedFileName(task.title, task.season, task.episode),
      subtitlePath: hasCaption ? captionPath : null,
      subtitleFileName: hasCaption
          ? sharedSubtitleFileName(task.title, task.season, task.episode)
          : null,
    );
    if (shared == null) return;
    final latest = library.downloads[task.key];
    if (latest == null || latest.path != file.path) {
      // A newer generation replaced this download while the copy was running.
      await deleteSharedFile(shared['video']);
      await deleteSharedFile(shared['subtitle']);
      return;
    }
    await library.addDownload(
      SavedDownload(
        latest.title,
        latest.season,
        latest.episode,
        latest.resolution,
        latest.path,
        latest.subtitlePath,
        thumbnailPath: latest.thumbnailPath,
        sharedPath: shared['video'],
        sharedSubtitlePath: shared['subtitle'],
      ),
    );
  }

  Future<void> _discardSavedFile(DownloadTask task, String path) async {
    if (library.downloads[task.key]?.path == path) {
      library.downloads.remove(task.key);
      await library._saveDownloads();
    }
  }

  Future<void> _reconcile() async {
    final records = {
      for (final record in await backend.records()) record.taskId: record,
    };
    final pending = {
      for (final task in await backend.pending()) task.taskId: task,
    };
    for (final nativeTask in pending.values) {
      if (_find(nativeTask.taskId) == null) {
        if (nativeTask is native.DownloadTask) retire(nativeTask);
      }
    }
    await save();
    await cleanTombstones();
    for (final task in tasks.values.toList()) {
      final video = task._video;
      if (task.cancelled || task._starting) continue;
      if (video == null || tombstones.containsKey(video.taskId)) {
        if (task.active && task._stream != null) {
          await replaceGeneration(task, refresh: true);
        }
        continue;
      }
      for (final candidate in [video, task._subtitle]) {
        if (candidate == null || !_current(task, candidate.taskId)) continue;
        final record = records[candidate.taskId];
        if (record != null) {
          await _apply(
            native.TaskProgressUpdate(
              candidate,
              record.progress,
              record.expectedFileSize,
            ),
          );
          await _apply(
            native.TaskStatusUpdate(candidate, record.status, record.exception),
          );
        }
      }
      if (!_current(task, video.taskId)) continue;
      // Desktop workers copy to the final path before reporting completion.
      if (!pending.containsKey(video.taskId)) {
        if (await File(DownloadTask._path(video)!).exists()) {
          await _finalize(task);
        } else if (task.complete) {
          library.downloads.remove(task.key);
          await library._saveDownloads();
          task._state = 'failed';
          task.error =
              'The downloaded file is missing. Retry to download it again.';
        } else if (task.active && !task.paused) {
          await replaceGeneration(task);
          continue;
        }
      }
      final subtitle = task._subtitle;
      if (subtitle != null &&
          _current(task, subtitle.taskId) &&
          task._captionState != 'complete' &&
          task._captionState != 'failed' &&
          !pending.containsKey(subtitle.taskId)) {
        if (await File(DownloadTask._path(subtitle)!).exists()) {
          task._captionState = 'complete';
          if (task.complete) await _finalize(task);
        } else {
          try {
            await backend.requestNotifications();
            if (!await backend.enqueue(subtitle)) task._captionState = 'failed';
          } catch (failure) {
            task._captionState = 'failed';
            task.error = '$failure';
          }
        }
      }
      task._notify();
    }
    await save();
  }

  void dispose() {
    _disposed = true;
    if (_backendStarted) backend.dispose();
    for (final task in tasks.values) {
      if (!task._disposed) task.dispose();
    }
  }
}

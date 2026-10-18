import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:background_downloader/background_downloader.dart' as native;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'desktop.dart';
import 'download_backend.dart';
import 'download_probe.dart';
import 'model.dart';

part 'downloads.dart';

const mediaChannel = MethodChannel('dev.r3ap3r.movie_box_app/media');

bool get _foreground =>
    WidgetsBinding.instance.lifecycleState == null ||
    WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

Future<String?> extractThumbnail(String path) async {
  if (isDesktopWindow || !_foreground) {
    return null;
  }
  try {
    return await mediaChannel.invokeMethod<String>('thumbnail', path);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Copies finished downloads into the phone's public Downloads folder.
/// Returns the video and subtitle locations, or null when unavailable.
Future<Map<String, String?>?> exportToDownloads({
  required String path,
  required String relativePath,
  required String fileName,
  String? subtitlePath,
  String? subtitleFileName,
}) async {
  if (isDesktopWindow) return null;
  try {
    return await mediaChannel.invokeMapMethod<String, String?>(
      'exportToDownloads',
      {
        'path': path,
        'relativePath': relativePath,
        'fileName': fileName,
        'subtitlePath': ?subtitlePath,
        'subtitleFileName': ?subtitleFileName,
      },
    );
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Removes an exported copy; content URIs need the platform, plain paths do not.
Future<void> deleteSharedFile(String? location) async {
  if (location == null) return;
  if (!location.startsWith('content://')) {
    await _deleteFile(location);
    return;
  }
  try {
    await mediaChannel.invokeMethod<void>('deleteSharedFile', location);
  } on PlatformException {
    // The entry is already gone, or the platform refused; nothing to clean up.
  } on MissingPluginException {
    // No platform implementation (desktop or tests).
  }
}

String _safeSegment(String value) {
  final cleaned = value
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final trimmed = cleaned.replaceAll(RegExp(r'[. ]+$'), '');
  if (trimmed.isEmpty) return 'MovieBox';
  return trimmed.length > 80 ? trimmed.substring(0, 80).trim() : trimmed;
}

String sharedEpisodeFolder(int season, int episode) =>
    'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

/// `movie-box/<name>/` for a film, `movie-box/<name>/<SxxExx>/` for an episode.
String sharedRelativePath(MovieTitle title, int season, int episode) {
  final name = _safeSegment(title.title);
  if (season <= 0 || episode <= 0) return 'movie-box/$name';
  return 'movie-box/$name/${sharedEpisodeFolder(season, episode)}';
}

String sharedFileName(MovieTitle title, int season, int episode) {
  final name = _safeSegment(title.title);
  if (season <= 0 || episode <= 0) return '$name.mp4';
  return '$name ${sharedEpisodeFolder(season, episode)}.mp4';
}

String sharedSubtitleFileName(MovieTitle title, int season, int episode) {
  final name = _safeSegment(title.title);
  if (season <= 0 || episode <= 0) return '$name.srt';
  return '$name ${sharedEpisodeFolder(season, episode)}.srt';
}

class MovieLibrary extends ChangeNotifier {
  final SharedPreferences prefs;
  final DownloadBackend? downloadBackend;
  final Future<Directory> Function()? downloadsDirectory;
  final MovieApi Function(String server, String token)? downloadApiFactory;
  bool _disposed = false;
  late final _DownloadCoordinator _coordinator = _DownloadCoordinator(this);
  late String server =
      prefs.getString('server') ?? 'https://movie-box.n92dev.us.kg';
  late String token = prefs.getString('token') ?? '';
  late final Map<String, WatchEntry> history = {
    for (final item in jsonDecode(prefs.getString('history') ?? '[]') as List)
      (WatchEntry.fromJson(item as Map<String, dynamic>))
          .key: WatchEntry.fromJson(
        item,
      ),
  };
  late final Map<String, MovieTitle> bookmarks = {
    for (final item in jsonDecode(prefs.getString('bookmarks') ?? '[]') as List)
      (MovieTitle.fromJson(item as Map<String, dynamic>))
          .path: MovieTitle.fromJson(
        item,
      ),
  };
  late final Map<String, SavedDownload> downloads = {
    for (final item in jsonDecode(prefs.getString('downloads') ?? '[]') as List)
      (SavedDownload.fromJson(item as Map<String, dynamic>))
          .key: SavedDownload.fromJson(
        item,
      ),
  };

  MovieLibrary(
    this.prefs, {
    this.downloadBackend,
    this.downloadsDirectory,
    this.downloadApiFactory,
  });

  Map<String, DownloadTask> get downloadTasks =>
      Map.unmodifiable(_coordinator.tasks);

  DownloadTask taskFor(MovieTitle title, int season, int episode) =>
      _coordinator.taskFor(title, season, episode);

  Future<void> initializeDownloads() => _coordinator.initialize();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String get captionPlace {
    final value = prefs.getString('caption_place');
    return value == 'top' || value == 'middle' || value == 'bottom'
        ? value!
        : 'bottom';
  }

  double get captionOpacity =>
      (prefs.getDouble('caption_opacity') ?? 0.75).clamp(0.0, 1.0).toDouble();

  double get captionSize =>
      (prefs.getDouble('caption_size') ?? 18).clamp(14.0, 32.0).toDouble();

  /// Last chosen track label, including "Off". Null until the user picks one.
  String? get captionLanguage => prefs.getString('caption_language');

  Future<void> saveCaptionStyle({
    required String place,
    required double opacity,
    required double size,
  }) async {
    await prefs.setString('caption_place', place);
    await prefs.setDouble('caption_opacity', opacity);
    await prefs.setDouble('caption_size', size);
  }

  Future<void> saveCaptionLanguage(String label) async {
    await prefs.setString('caption_language', label);
  }

  Future<void> configure(String address, String apiToken) async {
    server = address.replaceAll(RegExp(r'/$'), '');
    token = apiToken;
    await prefs.setString('server', server);
    await prefs.setString('token', token);
    _notify();
  }

  Future<void> record(WatchEntry entry) async {
    if (entry.positionSeconds <= 0) return;
    if (entry.durationSeconds > 0 &&
        entry.positionSeconds >= entry.durationSeconds - 20) {
      history.remove(entry.key);
    } else {
      history.remove(entry.key);
      history[entry.key] = entry;
    }
    await prefs.setString(
      'history',
      jsonEncode(history.values.map((e) => e.toJson()).toList()),
    );
    _notify();
  }

  Future<void> removeHistory(String key) async {
    if (history.remove(key) == null) return;
    await prefs.setString(
      'history',
      jsonEncode(history.values.map((e) => e.toJson()).toList()),
    );
    _notify();
  }

  Future<void> toggleBookmark(MovieTitle title) async {
    if (bookmarks.containsKey(title.path)) {
      bookmarks.remove(title.path);
    } else {
      bookmarks[title.path] = title;
    }
    await prefs.setString(
      'bookmarks',
      jsonEncode(bookmarks.values.map((item) => item.toJson()).toList()),
    );
    _notify();
  }

  Future<void> addDownload(SavedDownload entry) async {
    downloads[entry.key] = entry;
    await _saveDownloads();
  }

  Future<void> backfillThumbnails() async {
    for (final entry in downloads.values.toList()) {
      if (!_foreground) return;
      if (!await File(entry.path).exists() ||
          (entry.thumbnailPath?.endsWith('.preview.jpg') == true &&
              await File(entry.thumbnailPath!).exists())) {
        continue;
      }
      final path = await extractThumbnail(entry.path);
      final current = downloads[entry.key];
      if (path != null && current != null && current.path == entry.path) {
        await addDownload(
          SavedDownload(
            current.title,
            current.season,
            current.episode,
            current.resolution,
            current.path,
            current.subtitlePath,
            thumbnailPath: path,
            sharedPath: current.sharedPath,
            sharedSubtitlePath: current.sharedSubtitlePath,
          ),
        );
        if (current.thumbnailPath != null && current.thumbnailPath != path) {
          await _deleteFile(current.thumbnailPath!);
        }
      } else if (path != null) {
        await _deleteFile(path);
      }
    }
  }

  Future<void> removeDownload(SavedDownload entry) async {
    // An old screen must not remove a newer generation for the same episode.
    if (downloads[entry.key]?.path != entry.path) return;
    final task = _coordinator.tasks[entry.key];
    if (task?._videoPath == entry.path) {
      await task!.cancel();
    } else {
      downloads.remove(entry.key);
      await _saveDownloads();
    }
    await _deleteFile(entry.path);
    await _deleteFile(entry.subtitlePath);
    await _deleteFile(entry.thumbnailPath);
    await deleteSharedFile(entry.sharedPath);
    await deleteSharedFile(entry.sharedSubtitlePath);
  }

  Future<void> _saveDownloads() async {
    if (!await prefs.setString(
      'downloads',
      jsonEncode(downloads.values.map((e) => e.toJson()).toList()),
    )) {
      throw const FileSystemException('Could not persist saved downloads.');
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _coordinator.dispose();
    super.dispose();
  }
}

Future<void> _deleteFile(String? path) async {
  if (path == null) return;
  try {
    await File(path).delete();
  } on FileSystemException catch (error) {
    if (await File(path).exists()) rethrow;
    // Native cancellation may have already removed the file.
    if (error.osError != null && error.osError!.errorCode != 2) rethrow;
  }
}

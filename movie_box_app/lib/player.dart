import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import 'api.dart';
import 'desktop.dart';
import 'download_controls.dart';
import 'download_probe.dart';
import 'library.dart';
import 'loading.dart';
import 'model.dart';

class PlayerScreen extends StatefulWidget {
  final MovieApi api;
  final MovieLibrary library;
  final MovieTitle title;
  final int season, episode;
  final SavedDownload? offline;
  final bool resume;
  const PlayerScreen({
    super.key,
    required this.api,
    required this.library,
    required this.title,
    required this.season,
    required this.episode,
    this.offline,
    this.resume = true,
  });
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? controller;
  MoviePlayback? playback;
  MovieStream? selected;
  SavedDownload? currentOffline;
  MovieDetail? detail;
  List<MovieCaption> captions = [];
  String captionLabel = 'Off';
  bool loading = true;
  String loadingLabel = 'Opening video';
  String? actionLoading;
  bool lastBuffering = false;
  bool lastPlaying = false;
  String? lastPlaybackError;
  bool fullscreen = false;
  bool rotatedFullscreen = false;
  bool tvImmersive = false;
  bool controlsVisible = true;
  final videoFocus = FocusNode(debugLabel: 'Video');
  final tvControlsFocus = FocusNode(debugLabel: 'TV controls');
  bool get desktopWindow => isDesktopWindow;
  bool get tvMode =>
      !desktopWindow &&
      MediaQuery.sizeOf(context).width >= 900 &&
      MediaQuery.sizeOf(context).shortestSide >= 500;
  bool get expandedControls => tvMode || fullscreen;
  Timer? controlsTimer;
  Timer? cueTimer;
  String? playbackCue;
  double volume = 1;
  bool muted = false;
  Offset? doubleTapPosition;
  String? error;
  int lastSaved = -1;
  int lastRendered = -1;
  late int season = widget.title.kind == 'movie' ? 0 : widget.season;
  late int episode = widget.title.kind == 'movie' ? 0 : widget.episode;
  bool preparingDownload = false;
  bool preferLocal = true;
  bool switchingPlayback = false;
  double playbackSpeed = 1;
  String? captionSource;
  Duration captionOffset = Duration.zero;
  double captionOpacity = 0.75;
  double captionSize = 18;
  String captionPlace = 'bottom';
  bool captionPanel = false;
  static const playbackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
  DownloadTask get downloadTask =>
      widget.library.taskFor(widget.title, season, episode);

  SavedDownload? localDownload() {
    final saved = widget
        .library
        .downloads[viewingKey(widget.title.path, season, episode)];
    if (saved == null || !File(saved.path).existsSync()) return null;
    return saved;
  }

  Widget playbackMenu({required bool expanded}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xCC101010),
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          onPressed: chooseSpeed,
          child: Text(speedLabel),
        ),
        const SizedBox(width: 6),
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: const Color(0xCC101010),
            foregroundColor: Colors.white,
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
          onPressed: chooseCaption,
          child: Text(expanded ? 'Subtitles: $captionLabel' : captionLabel),
        ),
      ],
    );
  }

  String get speedLabel {
    final text = playbackSpeed
        .toStringAsFixed(2)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
    return 'Speed ${text}x';
  }

  void refreshDownloads() {
    if (!mounted) return;
    final saved = preferLocal ? localDownload() : null;
    if (saved != null &&
        currentOffline?.path != saved.path &&
        controller != null &&
        !loading &&
        !switchingPlayback) {
      playLocal(saved);
    }
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    captionPlace = widget.library.captionPlace;
    captionOpacity = widget.library.captionOpacity;
    captionSize = widget.library.captionSize;
    currentOffline = widget.offline;
    widget.library.addListener(refreshDownloads);
    widget.api
        .detail(widget.title.path)
        .then((value) {
          if (mounted) setState(() => detail = value);
        })
        .catchError((_) {});
    initialize();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (tvMode && !tvImmersive) {
      tvImmersive = true;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else if (!tvMode && tvImmersive) {
      tvImmersive = false;
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> initialize() async {
    try {
      final saved = preferLocal ? (localDownload() ?? currentOffline) : null;
      if (saved != null) {
        if (!await File(saved.path).exists()) {
          throw ApiException(
            'This download is missing. Delete it from Downloads and download it again.',
          );
        }
        await playLocal(saved, resume: false);
      } else {
        playback = await widget.api.playback(
          widget.title.path,
          season,
          episode,
        );
        final streams =
            playback!.streams
                .where((s) => s.format.toUpperCase() == 'MP4' && !s.locked)
                .toList()
              ..sort(
                (a, b) => (int.tryParse(b.resolution) ?? 0).compareTo(
                  int.tryParse(a.resolution) ?? 0,
                ),
              );
        if (streams.isEmpty) {
          throw ApiException('No playable MP4 stream is available.');
        }
        await selectStream(streams.first, resume: false);
      }
      final ready = preferLocal ? localDownload() : null;
      if (ready != null && currentOffline?.path != ready.path) {
        await playLocal(ready, resume: false);
      }
      if (mounted) {
        setState(() {
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> attach(
    VideoPlayerController next, {
    Duration? at,
    bool play = true,
  }) async {
    try {
      await next.initialize();
      if (!mounted) {
        await next.dispose();
        return;
      }
      final savedSeconds = widget.resume
          ? widget
                    .library
                    .history[viewingKey(widget.title.path, season, episode)]
                    ?.positionSeconds ??
                0
          : 0;
      final position = at ?? Duration(seconds: savedSeconds);
      if (position > Duration.zero &&
          position < next.value.duration - const Duration(seconds: 5)) {
        await next.seekTo(position);
      }
      final previous = controller;
      controller = next;
      next.addListener(onProgress);
      if (previous != null) {
        previous.removeListener(onProgress);
        await previous.dispose();
      }
      await next.setPlaybackSpeed(playbackSpeed);
      if (play) await next.play();
      revealControls();
      if (mounted) setState(() {});
    } catch (_) {
      await next.dispose();
      rethrow;
    }
  }

  Future<void> playLocal(SavedDownload saved, {bool resume = true}) async {
    if (switchingPlayback) return;
    switchingPlayback = true;
    try {
      final position = resume ? controller?.value.position : null;
      final playing = !resume || (controller?.value.isPlaying ?? true);
      await attach(
        VideoPlayerController.file(File(saved.path)),
        at: position,
        play: playing,
      );
      currentOffline = saved;
      selected = null;
      captions = [];
      captionLabel = 'Off';
      captionSource = null;
      captionOffset = Duration.zero;
      final path = saved.subtitlePath;
      if (widget.library.captionLanguage != 'Off' &&
          path != null &&
          await File(path).exists()) {
        final text = await File(path).readAsString();
        if (mounted && controller != null) {
          await showCaptions(text, 'Saved subtitles');
        }
      }
      if (mounted) setState(() {});
    } finally {
      switchingPlayback = false;
    }
  }

  Future<void> selectStream(MovieStream stream, {bool resume = true}) async {
    final position = resume ? controller?.value.position : null;
    await attach(
      VideoPlayerController.networkUrl(
        Uri.parse(stream.url),
        // The Android player otherwise sends User-Agent "ExoPlayer", which
        // this CDN answers with HTTP 428.
        httpHeaders: downloadRequestHeaders(stream.headers),
      ),
      at: position,
      play: !resume || (controller?.value.isPlaying ?? true),
    );
    selected = stream;
    captions = [];
    captionLabel = 'Off';
    captionSource = null;
    if (mounted) {
      setState(() {
        if (loading && loadingLabel != 'Switching quality') {
          loadingLabel = 'Loading subtitles';
        }
      });
    }
    await loadEnglish(stream);
  }

  Future<void> loadEnglish(MovieStream stream) async {
    try {
      final tracks = await widget.api.captions(
        widget.title.path,
        stream.id,
        season,
        episode,
      );
      if (!mounted || selected != stream) return;
      captions = tracks;
      final preferred = widget.library.captionLanguage;
      if (preferred == 'Off') return;
      final english = tracks
          .where((item) => item.language.toLowerCase().startsWith('en'))
          .firstOrNull;
      final chosen = preferred == null
          ? english
          : tracks
                    .where(
                      (item) =>
                          item.label == preferred ||
                          item.language.toLowerCase() ==
                              preferred.toLowerCase(),
                    )
                    .firstOrNull ??
                english;
      if (chosen == null) return;
      final response = await http.get(
        Uri.parse(chosen.url),
        headers: chosen.headers,
      );
      if (response.statusCode != 200 && response.statusCode != 206) return;
      if (!mounted || selected != stream || controller == null) return;
      await showCaptions(
        utf8.decode(response.bodyBytes, allowMalformed: true),
        chosen.label,
      );
      if (mounted) setState(() {});
    } catch (_) {}
  }

  void savePosition() {
    final player = controller;
    if (player == null || !player.value.isInitialized) return;
    final position = player.value.position.inSeconds;
    if (position > 0) {
      widget.library.record(
        WatchEntry(
          widget.title,
          season,
          episode,
          position,
          player.value.duration.inSeconds,
        ),
      );
    }
  }

  void onProgress() {
    final player = controller;
    if (player == null || !mounted) return;
    final seconds = player.value.position.inSeconds;
    if (seconds > 0 && (lastSaved < 0 || (seconds - lastSaved).abs() >= 5)) {
      lastSaved = seconds;
      savePosition();
    }
    if (seconds != lastRendered ||
        player.value.isBuffering != lastBuffering ||
        player.value.isPlaying != lastPlaying ||
        player.value.errorDescription != lastPlaybackError) {
      lastRendered = seconds;
      lastBuffering = player.value.isBuffering;
      lastPlaying = player.value.isPlaying;
      lastPlaybackError = player.value.errorDescription;
      setState(() {});
    }
  }

  Future<void> changeEpisode(int newSeason, int newEpisode) async {
    if (loading ||
        preparingDownload ||
        (season == newSeason && episode == newEpisode)) {
      return;
    }
    savePosition();
    final previous = controller;
    previous?.removeListener(onProgress);
    setState(() {
      controller = null;
      loading = true;
      loadingLabel = 'Loading episode';
      error = null;
    });
    await previous?.dispose();
    if (!mounted) return;
    setState(() {
      season = newSeason;
      episode = newEpisode;
      lastSaved = -1;
      lastRendered = -1;
      selected = null;
      playback = null;
      captions = [];
      captionLabel = 'Off';
      captionOffset = Duration.zero;
      captionPanel = false;
      preferLocal = true;
      currentOffline = localDownload();
      loading = true;
      error = null;
    });
    await initialize();
  }

  Future<T> withLoading<T>(String label, Future<T> Function() operation) async {
    if (mounted) setState(() => actionLoading = label);
    try {
      return await operation();
    } finally {
      if (mounted) setState(() => actionLoading = null);
    }
  }

  Future<void> chooseCaption() async {
    if (captionPanel) {
      setState(() => captionPanel = false);
      return;
    }
    if (loading || actionLoading != null) return;
    if (controller == null) return;
    revealControls();
    if (currentOffline != null) {
      final path = currentOffline!.subtitlePath;
      final hasSaved = path != null && await File(path).exists();
      if (!hasSaved && captions.isEmpty) {
        try {
          final tracks = await remoteCaptions();
          if (mounted) captions = tracks;
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => captionPanel = true);
      return;
    }
    try {
      if (captions.isEmpty) {
        captions = await withLoading(
          'Loading subtitles',
          () => widget.api.captions(
            widget.title.path,
            selected!.id,
            season,
            episode,
          ),
        );
      }
      if (!mounted) return;
      setState(() => captionPanel = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> pickCaption(Object choice) async {
    setState(() => captionPanel = false);
    final player = controller;
    if (player == null || !mounted) return;
    final path = currentOffline?.subtitlePath;
    if (choice == true && path != null) {
      await showCaptions(
        await File(path).readAsString(),
        'Saved subtitles',
        remember: true,
      );
    } else if (choice is MovieCaption) {
      await applyRemoteCaption(player, choice, remember: true);
    } else {
      await showCaptions(null, 'Off', remember: true);
    }
    if (mounted) setState(() {});
  }

  Future<List<MovieCaption>> remoteCaptions() async {
    playback ??= await widget.api.playback(widget.title.path, season, episode);
    final stream = playback!.streams
        .where((item) => item.format.toUpperCase() == 'MP4' && !item.locked)
        .firstOrNull;
    if (stream == null) return [];
    return widget.api.captions(widget.title.path, stream.id, season, episode);
  }

  Future<void> applyRemoteCaption(
    VideoPlayerController player,
    MovieCaption caption, {
    bool remember = false,
  }) async {
    final response = await withLoading(
      'Loading subtitles',
      () => http.get(Uri.parse(caption.url), headers: caption.headers),
    );
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw ApiException('Subtitles returned HTTP ${response.statusCode}.');
    }
    await showCaptions(
      utf8.decode(response.bodyBytes, allowMalformed: true),
      caption.label,
      remember: remember,
    );
  }

  Future<void> showCaptions(
    String? source,
    String label, {
    bool remember = false,
  }) async {
    captionSource = source;
    captionLabel = label;
    if (remember) await widget.library.saveCaptionLanguage(label);
    await refreshCaptionFile();
  }

  Future<void> rememberCaptionStyle() => widget.library.saveCaptionStyle(
    place: captionPlace,
    opacity: captionOpacity,
    size: captionSize,
  );

  Future<void> refreshCaptionFile() async {
    final player = controller;
    if (player == null) return;
    if (captionSource == null) {
      await player.setClosedCaptionFile(null);
      return;
    }
    final shifted = [
      for (final caption in SrtCaptions.parse(captionSource!))
        Caption(
          number: caption.number,
          start: caption.start + captionOffset,
          end: caption.end + captionOffset,
          text: caption.text,
        ),
    ];
    await player.setClosedCaptionFile(Future.value(FixedCaptions(shifted)));
  }

  String get captionOffsetLabel {
    final seconds = captionOffset.inMilliseconds / 1000;
    final sign = seconds > 0 ? '+' : '';
    return '$sign${seconds.toStringAsFixed(1)}s';
  }

  Object _captionChoice(bool hasSaved) {
    if (captionLabel == 'Saved subtitles' && hasSaved) return true;
    for (final caption in captions) {
      if (caption.label == captionLabel) return caption;
    }
    return false;
  }

  Widget captionSidePanel() {
    final savedPath = currentOffline?.subtitlePath;
    final hasSaved = savedPath != null && File(savedPath).existsSync();
    return Material(
      color: const Color(0xF0101519),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: const Text('Subtitles'),
                trailing: IconButton(
                  tooltip: 'Close subtitles',
                  onPressed: () => setState(() => captionPanel = false),
                  icon: const Icon(Icons.close),
                ),
              ),
              const ListTile(title: Text('Position')),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Wrap(
                  spacing: 4,
                  children: [
                    for (final place in ['top', 'middle', 'bottom'])
                      ChoiceChip(
                        label: Text(
                          place[0].toUpperCase() + place.substring(1),
                        ),
                        selected: captionPlace == place,
                        onSelected: (_) {
                          setState(() => captionPlace = place);
                          rememberCaptionStyle();
                        },
                      ),
                  ],
                ),
              ),
              ListTile(
                title: const Text('Timing'),
                subtitle: Text(
                  captionOffset == Duration.zero
                      ? 'In sync'
                      : 'Subtitles ${captionOffset.isNegative ? 'earlier' : 'later'} by ${captionOffsetLabel.replaceFirst('-', '')}',
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Subtitles earlier',
                    onPressed: () async {
                      captionOffset -= const Duration(milliseconds: 500);
                      await refreshCaptionFile();
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.remove),
                  ),
                  Text(captionOffsetLabel),
                  IconButton(
                    tooltip: 'Subtitles later',
                    onPressed: () async {
                      captionOffset += const Duration(milliseconds: 500);
                      await refreshCaptionFile();
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Text(
                  'Background',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Slider(
                value: captionOpacity,
                onChanged: (value) {
                  setState(() => captionOpacity = value);
                  rememberCaptionStyle();
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'Text size',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Slider(
                min: 14,
                max: 32,
                value: captionSize,
                onChanged: (value) {
                  setState(() => captionSize = value);
                  rememberCaptionStyle();
                },
              ),
              const ListTile(title: Text('Language')),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DropdownButton<Object>(
                  isExpanded: true,
                  value: _captionChoice(hasSaved),
                  items: [
                    const DropdownMenuItem(value: false, child: Text('Off')),
                    if (hasSaved)
                      const DropdownMenuItem(
                        value: true,
                        child: Text('Saved subtitles'),
                      ),
                    for (final caption in captions)
                      DropdownMenuItem(
                        value: caption,
                        child: Text(caption.label),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) pickCaption(value);
                  },
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Text(
                  'Position, background, text size, and language are kept for every video. Timing is only for this one.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFBCC8C9)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> chooseSpeed() async {
    if (loading || actionLoading != null || controller == null) return;
    final choice = await showModalBottomSheet<double>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Playback speed')),
            for (final speed in playbackSpeeds)
              ListTile(
                title: Text(speed == 1 ? '1x' : '${speed}x'),
                trailing: speed == playbackSpeed
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, speed),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted || controller == null) return;
    await controller!.setPlaybackSpeed(choice);
    setState(() => playbackSpeed = choice);
  }

  RelativeRect? qualityMenuPosition;

  RelativeRect menuAnchor(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(buttonContext).overlay!.context.findRenderObject()!
            as RenderBox;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    return RelativeRect.fromRect(
      Rect.fromLTWH(origin.dx, origin.dy, box.size.width, box.size.height),
      Offset.zero & overlay.size,
    );
  }

  Future<void> chooseQuality() async {
    if (loading || actionLoading != null) return;
    try {
      playback ??= await withLoading(
        'Loading qualities',
        () => widget.api.playback(widget.title.path, season, episode),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (!mounted) return;
    final streams = playback!.streams
        .where((s) => s.format.toUpperCase() == 'MP4' && !s.locked)
        .toList();
    if (streams.isEmpty) return;
    final choice = desktopWindow
        ? await showMenu<MovieStream>(
            context: context,
            position:
                qualityMenuPosition ?? const RelativeRect.fromLTRB(0, 0, 0, 0),
            constraints: const BoxConstraints(minWidth: 148, maxWidth: 168),
            items: [
              for (final stream in streams.reversed)
                PopupMenuItem(
                  value: stream,
                  height: 36,
                  child: Row(
                    children: [
                      Expanded(child: Text('${stream.resolution}p')),
                      if (stream.id == selected?.id)
                        const Icon(Icons.check, size: 16),
                    ],
                  ),
                ),
            ],
          )
        : await showModalBottomSheet<MovieStream>(
            context: context,
            builder: (_) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(title: Text('Playback quality')),
                  for (final stream in streams.reversed)
                    ListTile(
                      title: Text('${stream.resolution}p'),
                      trailing: stream.id == selected?.id
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.pop(context, stream),
                    ),
                ],
              ),
            ),
          );
    if (choice == null || choice.id == selected?.id || !mounted) return;
    setState(() {
      loading = true;
      loadingLabel = 'Switching quality';
    });
    try {
      final fresh = await widget.api.playback(
        widget.title.path,
        season,
        episode,
      );
      final stream = fresh.streams.firstWhere(
        (s) => s.format == choice.format && s.resolution == choice.resolution,
      );
      await selectStream(stream);
      playback = fresh;
      if (mounted) {
        setState(() {
          preferLocal = false;
          currentOffline = null;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not switch quality: $e')));
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> downloadCurrent() async {
    if (loading ||
        preparingDownload ||
        actionLoading != null ||
        currentOffline != null ||
        downloadTask.active) {
      return;
    }
    setState(() => preparingDownload = true);
    try {
      final fresh = await withLoading(
        'Getting download options',
        () => widget.api.playback(widget.title.path, season, episode),
      );
      if (!mounted) return;
      final streams = fresh.streams
          .where((s) => s.format.toUpperCase() == 'MP4' && !s.locked)
          .toList();
      if (streams.isEmpty) {
        throw ApiException('No downloadable MP4 stream is available.');
      }
      final stream = await showModalBottomSheet<MovieStream>(
        context: context,
        builder: (_) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Download quality')),
              for (final item in streams.reversed)
                ListTile(
                  title: Text('${item.resolution}p'),
                  subtitle: Text(
                    item.size == null
                        ? 'MP4'
                        : '${(item.size! / 1048576).round()} MB · MP4',
                  ),
                  onTap: () => Navigator.pop(context, item),
                ),
            ],
          ),
        ),
      );
      if (stream == null || !mounted) return;
      List<MovieCaption> available;
      try {
        available = await withLoading(
          'Loading subtitles',
          () => widget.api.captions(
            widget.title.path,
            stream.id,
            season,
            episode,
          ),
        );
      } catch (_) {
        available = [];
      }
      if (!mounted) return;
      final option = await showModalBottomSheet<Object>(
        context: context,
        builder: (_) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Save subtitles with the video')),
              ListTile(
                title: const Text('Video only'),
                onTap: () => Navigator.pop(context, false),
              ),
              for (final caption in available)
                ListTile(
                  title: Text(caption.label),
                  onTap: () => Navigator.pop(context, caption),
                ),
            ],
          ),
        ),
      );
      if (option == null || !mounted) return;
      final saved = await downloadTask.start(
        widget.api,
        widget.library,
        detail?.title ?? widget.title,
        season,
        episode,
        stream,
        option == false ? null : option as MovieCaption,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saved == null
                  ? 'Download started in the background. Open Downloads to track it or play offline when ready.'
                  : 'Already downloaded. Open Downloads to play offline.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => preparingDownload = false);
    }
  }

  void revealControls() {
    controlsTimer?.cancel();
    if (mounted && !controlsVisible) setState(() => controlsVisible = true);
    controlsTimer = Timer(
      Duration(seconds: desktopWindow ? 4 : 3),
      () {
        final playing = controller?.value.isPlaying == true;
        if (mounted &&
            (desktopWindow || playing) &&
            !tvControlsFocus.hasFocus &&
            (!videoFocus.hasFocus || videoFocus.hasPrimaryFocus)) {
          setState(() => controlsVisible = false);
        }
      },
    );
  }

  void toggleControls() {
    if (controlsVisible) {
      controlsTimer?.cancel();
      setState(() => controlsVisible = false);
    } else {
      revealControls();
    }
  }

  void togglePlayback() {
    final player = controller;
    if (player == null) return;
    player.value.isPlaying ? player.pause() : player.play();
    revealControls();
  }

  void showCue(String text) {
    cueTimer?.cancel();
    setState(() => playbackCue = text);
    cueTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => playbackCue = null);
    });
  }

  void seekBy(int seconds) {
    final player = controller;
    if (player == null || !player.value.isInitialized) return;
    final target = player.value.position + Duration(seconds: seconds);
    player.seekTo(
      target < Duration.zero
          ? Duration.zero
          : target > player.value.duration
          ? player.value.duration
          : target,
    );
    showCue(seconds < 0 ? '$seconds s' : '+$seconds s');
    revealControls();
  }

  void seekFraction(double fraction) {
    final player = controller;
    if (player == null || !player.value.isInitialized) return;
    final target = player.value.duration * fraction.clamp(0, 1);
    player.seekTo(target);
    showCue('${(fraction * 100).round()}%');
    revealControls();
  }

  void changeVolume(double delta) {
    final player = controller;
    if (player == null) return;
    muted = false;
    volume = (volume + delta).clamp(0, 1);
    player.setVolume(volume);
    showCue(volume == 0 ? 'Muted' : 'Volume ${(volume * 100).round()}%');
    revealControls();
  }

  void toggleMute() {
    final player = controller;
    if (player == null) return;
    muted = !muted;
    player.setVolume(muted ? 0 : volume);
    showCue(muted ? 'Muted' : 'Volume ${(volume * 100).round()}%');
    revealControls();
  }

  void cycleSpeed(int direction) {
    final index = playbackSpeeds.indexOf(playbackSpeed);
    final next = (index < 0 ? 2 : index + direction).clamp(
      0,
      playbackSpeeds.length - 1,
    );
    final speed = playbackSpeeds[next];
    playbackSpeed = speed;
    controller?.setPlaybackSpeed(speed);
    showCue(speedLabel);
    revealControls();
  }

  Future<void> toggleFullscreen() async {
    if (desktopWindow) {
      try {
        await mediaChannel.invokeMethod<void>('setFullscreen', !fullscreen);
      } on MissingPluginException {
        // A desktop runner without the native handler keeps its windowed size.
        return;
      }
      if (mounted) setState(() => fullscreen = !fullscreen);
      revealControls();
      return;
    }
    if (fullscreen) {
      if (rotatedFullscreen) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      }
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      rotatedFullscreen = false;
    } else {
      rotatedFullscreen = MediaQuery.sizeOf(context).shortestSide < 500;
      if (rotatedFullscreen) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    if (mounted) setState(() => fullscreen = !fullscreen);
    revealControls();
  }

  String? get loadingMessage {
    if (loading) return loadingLabel;
    if (actionLoading != null) return actionLoading;
    if (controller?.value.isBuffering == true &&
        controller?.value.hasError != true) {
      return 'Buffering video';
    }
    return null;
  }

  Widget videoSurface(
    VideoPlayerController? player, {
    double panelHeight = 0,
  }) => Focus(
    focusNode: videoFocus,
    autofocus: true,
    onKeyEvent: (_, event) {
      if (!videoFocus.hasPrimaryFocus ||
          (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
        return KeyEventResult.ignored;
      }
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.keyJ) {
        seekBy(-10);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight ||
          key == LogicalKeyboardKey.keyL) {
        seekBy(10);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        if (desktopWindow) {
          changeVolume(0.05);
        } else if (!controlsVisible) {
          revealControls();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        if (desktopWindow) {
          changeVolume(-0.05);
        } else if (!controlsVisible) {
          revealControls();
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyM) {
        if (event is KeyDownEvent) toggleMute();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.comma) {
        cycleSpeed(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.period) {
        cycleSpeed(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.home) {
        seekFraction(0);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.end) {
        seekFraction(1);
        return KeyEventResult.handled;
      }
      final digits = {
        LogicalKeyboardKey.digit0: 0.0,
        LogicalKeyboardKey.digit1: 0.1,
        LogicalKeyboardKey.digit2: 0.2,
        LogicalKeyboardKey.digit3: 0.3,
        LogicalKeyboardKey.digit4: 0.4,
        LogicalKeyboardKey.digit5: 0.5,
        LogicalKeyboardKey.digit6: 0.6,
        LogicalKeyboardKey.digit7: 0.7,
        LogicalKeyboardKey.digit8: 0.8,
        LogicalKeyboardKey.digit9: 0.9,
      };
      final fraction = digits[key];
      if (fraction != null) {
        seekFraction(fraction);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.keyK) {
        if (event is KeyDownEvent) togglePlayback();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Builder(
      builder: (context) {
        final initialized = player != null && player.value.isInitialized;
        final videoRatio = initialized && player.value.aspectRatio > 0
            ? player.value.aspectRatio
            : 16 / 9;
        final stage = AspectRatio(
          aspectRatio: fullscreen
              ? MediaQuery.sizeOf(context).aspectRatio
              : (desktopWindow ? videoRatio : 16 / 9),
          child: _videoBody(player, panelHeight),
        );
        if (!desktopWindow || fullscreen) return stage;
        return SizedBox(
          width: double.infinity,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.62,
              ),
              child: stage,
            ),
          ),
        );
      },
    ),
  );

  Widget _videoBody(VideoPlayerController? player, double panelHeight) =>
      ColoredBox(
        color: Colors.black,
        child:
            !loading &&
                ((error != null && player == null) ||
                    player?.value.hasError == true)
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        error ??
                            player?.value.errorDescription ??
                            'Playback failed.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          loading = true;
                          loadingLabel = 'Opening video';
                          error = null;
                        });
                        initialize();
                      },
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              )
            : player == null || !player.value.isInitialized
            ? Center(child: MovieBoxLoader(label: loadingLabel))
            : Stack(
                alignment: Alignment.center,
                children: [
                  Center(
                    child: AspectRatio(
                      aspectRatio: player.value.aspectRatio,
                      child: VideoPlayer(player),
                    ),
                  ),
                  if (controlsVisible)
                    const Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 128,
                      child: IgnorePointer(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x00000000), Color(0xE6101010)],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: Builder(
                      builder: (stageContext) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: toggleControls,
                        onDoubleTapDown: (details) =>
                            doubleTapPosition = details.localPosition,
                        onDoubleTap: () {
                          final x = doubleTapPosition?.dx ?? 0;
                          final box =
                              stageContext.findRenderObject() as RenderBox?;
                          final width = box?.size.width ?? 1;
                          if (x < width / 2) {
                            seekBy(-10);
                          } else {
                            seekBy(10);
                          }
                        },
                      ),
                    ),
                  ),
                  if (player.value.caption.text.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Align(
                          alignment: switch (captionPlace) {
                            'top' => Alignment.topCenter,
                            'middle' => Alignment.center,
                            _ => Alignment.bottomCenter,
                          },
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              16,
                              controlsVisible ? 56 : 16,
                              16,
                              controlsVisible ? 72 : 16,
                            ),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color.fromARGB(
                                  (captionOpacity * 255).round(),
                                  0,
                                  0,
                                  0,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                child: Text(
                                  player.value.caption.text,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: captionSize,
                                    color: Colors.white,
                                    height: 1.25,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    child: playbackCue == null
                        ? const SizedBox.shrink()
                        : Center(
                            key: ValueKey(playbackCue),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0xCC101519),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 10,
                                ),
                                child: Text(
                                  playbackCue!,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                  if (controlsVisible && desktopWindow) desktopDock(player),
                  if (controlsVisible && !desktopWindow) ...[
                    Positioned.fill(
                      top: expandedControls ? 56 : 0,
                      bottom: expandedControls ? panelHeight + 48 : 0,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: 'Back 10 seconds',
                            icon: const Icon(Icons.replay_10),
                            onPressed: () => seekBy(-10),
                          ),
                          const SizedBox(width: 22),
                          IconButton(
                            tooltip: player.value.isPlaying ? 'Pause' : 'Play',
                            iconSize: 42,
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xFFF2B86B),
                              foregroundColor: const Color(0xFF1A1208),
                            ),
                            icon: Icon(
                              player.value.isPlaying
                                  ? Icons.pause_circle
                                  : Icons.play_circle,
                            ),
                            onPressed: togglePlayback,
                          ),
                          const SizedBox(width: 22),
                          IconButton(
                            tooltip: 'Forward 10 seconds',
                            icon: const Icon(Icons.forward_10),
                            onPressed: () => seekBy(10),
                          ),
                        ],
                      ),
                    ),
                    if (!expandedControls)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 0,
                        child: Row(
                          children: [
                            Text(
                              formatTime(player.value.position),
                              style: const TextStyle(fontSize: 12),
                            ),
                            Expanded(
                              child: VideoProgressIndicator(
                                player,
                                allowScrubbing: true,
                                padding: const EdgeInsets.all(8),
                                colors: const VideoProgressColors(
                                  playedColor: Color(0xFFF2B86B),
                                ),
                              ),
                            ),
                            Text(
                              formatTime(player.value.duration),
                              style: const TextStyle(fontSize: 12),
                            ),
                            IconButton(
                              tooltip: fullscreen
                                  ? 'Exit fullscreen'
                                  : 'Fullscreen',
                              icon: Icon(
                                fullscreen
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen,
                              ),
                              onPressed: toggleFullscreen,
                            ),
                          ],
                        ),
                      ),
                  ],
                  if (controlsVisible &&
                      player.value.isInitialized &&
                      !desktopWindow)
                    Positioned(
                      top: expandedControls ? 72 : 8,
                      right: 8,
                      child: playbackMenu(expanded: expandedControls),
                    ),
                  Positioned(
                    top: expandedControls && controlsVisible ? 56 : 12,
                    left: 12,
                    right: 12,
                    child: IgnorePointer(
                      child: AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 180),
                        child: loadingMessage == null
                            ? const SizedBox.shrink()
                            : Center(
                                key: const ValueKey('player-loading'),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: const Color(0xE6101519),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 8,
                                    ),
                                    child: MovieBoxLoader(
                                      label: loadingMessage!,
                                      compact: true,
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
      );

  List<(int, int)> get episodeOptions {
    if ((detail?.title ?? widget.title).kind == 'movie') return [];
    final seasons = detail?.seasons ?? [];
    if (seasons.isNotEmpty) {
      return [
        for (final item in seasons)
          for (var number = 1; number <= item.episodes; number++)
            (item.number, number),
      ];
    }
    final saved =
        widget.library.downloads.values
            .where(
              (item) => item.title.path == widget.title.path && item.season > 0,
            )
            .map((item) => (item.season, item.episode))
            .toList()
          ..sort(
            (a, b) =>
                a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
          );
    return saved;
  }

  (int, int)? adjacentEpisode(int direction) {
    final options = episodeOptions;
    final index = options.indexOf((season, episode));
    final next = index + direction;
    return index < 0 || next < 0 || next >= options.length
        ? null
        : options[next];
  }

  List<(int, int)> get mobileEpisodeOptions =>
      detail?.seasons.isNotEmpty == true
      ? episodeOptions.where((item) => item.$1 == season).toList()
      : episodeOptions;

  Widget mobileEpisodeSelector() {
    final options = mobileEpisodeOptions;
    final includeSeason = detail?.seasons.isNotEmpty != true;
    return DropdownButton<(int, int)>(
      key: const ValueKey('mobile-episode-selector'),
      value: options.contains((season, episode)) ? (season, episode) : null,
      hint: Text('Episode $episode'),
      items: [
        for (final item in options)
          DropdownMenuItem(
            value: item,
            child: Text(
              '${includeSeason ? 'S${item.$1} · ' : ''}Episode ${item.$2}',
            ),
          ),
      ],
      onTap: () => controlsTimer?.cancel(),
      onChanged: (value) {
        revealControls();
        if (value != null) changeEpisode(value.$1, value.$2);
      },
    );
  }

  Widget expandedPlayer(VideoPlayerController? player, MovieTitle info) {
    final seasons = detail?.seasons ?? [];
    final episodes = episodeOptions.where((item) => item.$1 == season).toList();
    final previous = adjacentEpisode(-1);
    final next = adjacentEpisode(1);
    return SafeArea(
      child: AnimatedBuilder(
        animation: downloadTask,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxWidth < 900 || constraints.maxHeight < 500;
            final panelHeight =
                (compact ? 84.0 : 102.0) +
                (tvMode && episodes.isNotEmpty ? 56 : 0) +
                (downloadTask.active ? 48 : 0);
            return Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: videoSurface(player, panelHeight: panelHeight),
                ),
                if (controlsVisible)
                  Focus(
                    focusNode: tvControlsFocus,
                    canRequestFocus: false,
                    child: Stack(
                      children: [
                        Positioned(
                          top: compact ? 0 : 12,
                          left: compact ? 8 : 16,
                          right: compact ? 8 : 16,
                          child: ColoredBox(
                            color: const Color(0xA6101519),
                            child: Row(
                              children: [
                                TextButton.icon(
                                  onPressed: () {
                                    if (fullscreen && !tvMode) {
                                      toggleFullscreen();
                                    } else {
                                      Navigator.maybePop(context);
                                    }
                                  },
                                  icon: const Icon(Icons.arrow_back),
                                  label: const Text('Back'),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Text(
                                    '${info.title}${season > 0 ? ' · S$season E$episode' : ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: compact
                                        ? Theme.of(context)
                                              .textTheme
                                              .titleMedium
                                        : Theme.of(context)
                                              .textTheme
                                              .titleLarge,
                                  ),
                                ),
                                if (fullscreen && !tvMode)
                                  IconButton(
                                    tooltip: 'Exit fullscreen',
                                    onPressed: toggleFullscreen,
                                    icon: const Icon(Icons.fullscreen_exit),
                                  ),
                                IconButton(
                                  tooltip:
                                      widget.library.bookmarks.containsKey(
                                        widget.title.path,
                                      )
                                      ? 'Remove bookmark'
                                      : 'Bookmark',
                                  icon: Icon(
                                    widget.library.bookmarks.containsKey(
                                          widget.title.path,
                                        )
                                        ? Icons.bookmark
                                        : Icons.bookmark_border,
                                  ),
                                  onPressed: () async {
                                    await widget.library.toggleBookmark(info);
                                    if (mounted) setState(() {});
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: compact
                                ? const EdgeInsets.fromLTRB(12, 8, 12, 8)
                                : const EdgeInsets.fromLTRB(20, 14, 20, 20),
                            color: const Color(0xEE101519),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (player != null &&
                                    player.value.isInitialized)
                                  Row(
                                    children: [
                                      Text(formatTime(player.value.position)),
                                      Expanded(
                                        child: VideoProgressIndicator(
                                          player,
                                          allowScrubbing: true,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                          colors: const VideoProgressColors(
                                            playedColor: Color(0xFFF2B86B),
                                          ),
                                        ),
                                      ),
                                      Text(formatTime(player.value.duration)),
                                    ],
                                  ),
                                SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: SizedBox(
                                    width: compact
                                        ? null
                                        : constraints.maxWidth - 40,
                                    child: Row(
                                      children: [
                                        if (seasons.isNotEmpty)
                                          DropdownButton<int>(
                                            value:
                                                seasons.any(
                                                  (item) =>
                                                      item.number == season,
                                                )
                                                ? season
                                                : seasons.first.number,
                                            items: [
                                              for (final item in seasons)
                                                DropdownMenuItem(
                                                  value: item.number,
                                                  child: Text(
                                                    'Season ${item.number}',
                                                  ),
                                                ),
                                            ],
                                            onTap: tvMode
                                                ? null
                                                : () => controlsTimer?.cancel(),
                                            onChanged: (value) {
                                              if (!tvMode) revealControls();
                                              if (value != null) {
                                                changeEpisode(value, 1);
                                              }
                                            },
                                          ),
                                        if (!tvMode &&
                                            mobileEpisodeOptions
                                                .isNotEmpty) ...[
                                          const SizedBox(width: 12),
                                          mobileEpisodeSelector(),
                                        ],
                                        if (info.kind != 'movie') ...[
                                          const SizedBox(width: 12),
                                          OutlinedButton.icon(
                                            onPressed: previous == null
                                                ? null
                                                : () => changeEpisode(
                                                    previous.$1,
                                                    previous.$2,
                                                  ),
                                            icon: const Icon(
                                              Icons.skip_previous,
                                            ),
                                            label: const Text('Previous'),
                                          ),
                                          const SizedBox(width: 8),
                                          OutlinedButton.icon(
                                            onPressed: next == null
                                                ? null
                                                : () => changeEpisode(
                                                    next.$1,
                                                    next.$2,
                                                  ),
                                            icon: const Icon(Icons.skip_next),
                                            label: const Text('Next'),
                                          ),
                                        ],
                                        if (compact)
                                          const SizedBox(width: 12)
                                        else
                                          const Spacer(),
                                        if (player?.value.isInitialized ==
                                            true) ...[
                                          OutlinedButton(
                                            onPressed: chooseQuality,
                                            child: Text(
                                              'Quality ${currentOffline?.resolution ?? selected?.resolution ?? ''}p',
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        OutlinedButton.icon(
                                          onPressed:
                                              currentOffline != null ||
                                                  downloadTask.active
                                              ? null
                                              : downloadCurrent,
                                          icon: const Icon(
                                            Icons.download_outlined,
                                          ),
                                          label: Text(
                                            currentOffline == null
                                                ? 'Download'
                                                : 'Saved',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (tvMode && episodes.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    height: 48,
                                    child: ListView.separated(
                                      scrollDirection: Axis.horizontal,
                                      itemCount: episodes.length,
                                      separatorBuilder: (_, _) =>
                                          const SizedBox(width: 8),
                                      itemBuilder: (_, index) {
                                        final item = episodes[index];
                                        return ChoiceChip(
                                          label: Text('Episode ${item.$2}'),
                                          selected: episode == item.$2,
                                          onSelected: (_) =>
                                              changeEpisode(item.$1, item.$2),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                                if (downloadTask.active)
                                  AnimatedBuilder(
                                    animation: downloadTask,
                                    builder: (_, _) => Row(
                                      children: [
                                        Expanded(
                                          child: LinearProgressIndicator(
                                            value:
                                                (downloadTask.total ?? 0) <= 0
                                                ? (downloadTask.paused
                                                      ? 0
                                                      : null)
                                                : (downloadTask.received /
                                                          downloadTask.total!)
                                                      .clamp(0.0, 1.0),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () async {
                                            try {
                                              if (downloadTask.paused) {
                                                await downloadTask.resume();
                                              } else {
                                                await downloadTask.pause();
                                              }
                                            } catch (error) {
                                              if (!context.mounted) return;
                                              ScaffoldMessenger.of(context)
                                                  .showSnackBar(
                                                    SnackBar(
                                                      content: Text('$error'),
                                                    ),
                                                  );
                                            }
                                          },
                                          child: Text(
                                            downloadTask.paused
                                                ? 'Resume download'
                                                : 'Pause download',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    controlsTimer?.cancel();
    cueTimer?.cancel();
    videoFocus.dispose();
    tvControlsFocus.dispose();
    if (desktopWindow && fullscreen) {
      unawaited(
        mediaChannel
            .invokeMethod<void>('setFullscreen', false)
            .catchError((Object _) {}),
      );
    } else if (fullscreen || tvImmersive) {
      if (rotatedFullscreen) {
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      }
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    savePosition();
    controller?.removeListener(onProgress);
    controller?.dispose();
    widget.library.removeListener(refreshDownloads);
    super.dispose();
  }

  Widget episodeRail(MovieTitle info) {
    final episodes = episodeOptions.where((item) => item.$1 == season).toList();
    final seasons = detail?.seasons ?? [];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF171D21),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 14, 14, 4),
            child: Text(
              'Season',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (seasons.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: DropdownButton<int>(
                isExpanded: true,
                value: seasons.any((item) => item.number == season)
                    ? season
                    : seasons.first.number,
                items: [
                  for (final item in seasons)
                    DropdownMenuItem(
                      value: item.number,
                      child: Text('Season ${item.number}'),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) changeEpisode(value, 1);
                },
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              itemCount: episodes.length,
              itemBuilder: (context, index) {
                final item = episodes[index];
                final current = item.$1 == season && item.$2 == episode;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Material(
                    color: current
                        ? const Color(0x33F2B86B)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: current
                          ? null
                          : () => changeEpisode(item.$1, item.$2),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: SizedBox(
                                width: 96,
                                height: 54,
                                child: (info.backdrop ?? info.poster) == null
                                    ? const ColoredBox(
                                        color: Color(0xFF273238),
                                        child: Icon(Icons.movie, size: 20),
                                      )
                                    : CachedNetworkImage(
                                        imageUrl:
                                            (info.backdrop ?? info.poster)!,
                                        fit: BoxFit.cover,
                                      ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                current
                                    ? 'Episode ${item.$2}\nPlaying'
                                    : 'Episode ${item.$2}',
                                style: TextStyle(
                                  fontWeight: current
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                  color: current
                                      ? const Color(0xFFF2B86B)
                                      : null,
                                  height: 1.25,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  (int, int)? neighborEpisode(int delta) {
    final index = episodeOptions.indexWhere(
      (item) => item.$1 == season && item.$2 == episode,
    );
    final next = index + delta;
    if (index < 0 || next < 0 || next >= episodeOptions.length) return null;
    return episodeOptions[next];
  }

  Widget desktopDock(VideoPlayerController player) {
    final previous = neighborEpisode(-1);
    final next = neighborEpisode(1);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00000000), Color(0xF2101519)],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 36, 12, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    formatTime(player.value.position),
                    style: const TextStyle(fontSize: 12),
                  ),
                  Expanded(
                    child: VideoProgressIndicator(
                      player,
                      allowScrubbing: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      colors: const VideoProgressColors(
                        playedColor: Color(0xFFF2B86B),
                        bufferedColor: Color(0x66F2B86B),
                        backgroundColor: Color(0x33FFFFFF),
                      ),
                    ),
                  ),
                  Text(
                    formatTime(player.value.duration),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: 'Previous episode',
                    onPressed: previous == null
                        ? null
                        : () => changeEpisode(previous.$1, previous.$2),
                    icon: const Icon(Icons.skip_previous),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Material(
                      color: const Color(0xFFF2B86B),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: togglePlayback,
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Icon(
                            player.value.isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            color: const Color(0xFF1A140C),
                            size: 28,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Next episode',
                    onPressed: next == null
                        ? null
                        : () => changeEpisode(next.$1, next.$2),
                    icon: const Icon(Icons.skip_next),
                  ),
                  IconButton(
                    tooltip: 'Back 10 seconds',
                    onPressed: () => seekBy(-10),
                    icon: const Icon(Icons.replay_10),
                  ),
                  IconButton(
                    tooltip: 'Forward 10 seconds',
                    onPressed: () => seekBy(10),
                    icon: const Icon(Icons.forward_10),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: muted ? 'Unmute' : 'Mute',
                    onPressed: toggleMute,
                    icon: Icon(
                      muted || volume == 0 ? Icons.volume_off : Icons.volume_up,
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: Slider(
                      value: muted ? 0 : volume,
                      onChanged: (value) {
                        setState(() {
                          volume = value;
                          muted = value == 0;
                        });
                        player.setVolume(value);
                        revealControls();
                      },
                    ),
                  ),
                  PopupMenuButton<double>(
                    tooltip: 'Speed',
                    initialValue: playbackSpeed,
                    constraints: const BoxConstraints(
                      minWidth: 120,
                      maxWidth: 140,
                    ),
                    offset: const Offset(0, -220),
                    onSelected: (speed) {
                      playbackSpeed = speed;
                      player.setPlaybackSpeed(speed);
                      showCue(speedLabel);
                    },
                    itemBuilder: (context) => [
                      for (final speed in playbackSpeeds)
                        PopupMenuItem(
                          value: speed,
                          child: Text(speed == 1 ? 'Normal' : '${speed}x'),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(speedLabel),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Subtitles',
                    onPressed: chooseCaption,
                    icon: const Icon(Icons.closed_caption),
                  ),
                  Builder(
                    builder: (buttonContext) => IconButton(
                      tooltip: 'Quality',
                      onPressed: currentOffline == null
                          ? () {
                              qualityMenuPosition = menuAnchor(buttonContext);
                              chooseQuality();
                            }
                          : null,
                      icon: const Icon(Icons.high_quality),
                    ),
                  ),
                  IconButton(
                    tooltip: fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                    onPressed: toggleFullscreen,
                    icon: Icon(
                      fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget desktopEpisodeStrip() {
    final episodes = episodeOptions.where((item) => item.$1 == season).toList();
    final seasons = detail?.seasons ?? [];
    return ColoredBox(
      color: const Color(0xFF12181C),
      child: SizedBox(
        height: 108,
        child: Column(
          children: [
            SizedBox(
              height: 36,
              child: Row(
                children: [
                  const SizedBox(width: 20),
                  const Text(
                    'Episodes',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  if (seasons.isNotEmpty)
                    DropdownButton<int>(
                      value: seasons.any((item) => item.number == season)
                          ? season
                          : seasons.first.number,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final item in seasons)
                          DropdownMenuItem(
                            value: item.number,
                            child: Text('Season ${item.number}'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) changeEpisode(value, 1);
                      },
                    ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
            SizedBox(
              height: 64,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: episodes.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final item = episodes[index];
                  final current = item.$1 == season && item.$2 == episode;
                  return Material(
                    color: current
                        ? const Color(0xFFF2B86B)
                        : const Color(0xFF1E272C),
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: current
                          ? null
                          : () => changeEpisode(item.$1, item.$2),
                      child: SizedBox(
                        width: 132,
                        child: Center(
                          child: Text(
                            current
                                ? 'Episode ${item.$2}  ·  Playing'
                                : 'Episode ${item.$2}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: current
                                  ? const Color(0xFF1A140C)
                                  : Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget desktopStage(VideoPlayerController? player, MovieTitle info) {
    final showRail = info.kind != 'movie' && episodeOptions.isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final ratio =
            player != null &&
                player.value.isInitialized &&
                player.value.aspectRatio > 0
            ? player.value.aspectRatio
            : 16 / 9;
        final railWidth = showRail ? 312.0 : 0.0;
        final videoWidth = (constraints.maxWidth - 32 - railWidth).clamp(
          240.0,
          constraints.maxWidth,
        );
        var videoHeight = videoWidth / ratio;
        final maxHeight = constraints.maxHeight * 0.68;
        if (videoHeight > maxHeight) videoHeight = maxHeight;
        return Column(
          children: [
            SizedBox(
              height: videoHeight + 8,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: ColoredBox(
                          color: Colors.black,
                          child: videoSurface(player),
                        ),
                      ),
                    ),
                    if (showRail) ...[
                      const SizedBox(width: 12),
                      SizedBox(width: 300, child: episodeRail(info)),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(child: desktopWatchPanel(info)),
            ),
          ],
        );
      },
    );
  }

  Widget desktopWatchPanel(MovieTitle info) {
    final poster = info.poster ?? info.backdrop;
    final seasons = detail?.seasons ?? [];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 112,
              height: 168,
              child: poster == null
                  ? const ColoredBox(
                      color: Color(0xFF273238),
                      child: Icon(Icons.movie_outlined),
                    )
                  : CachedNetworkImage(imageUrl: poster, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.title,
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  [
                    info.kind == 'series' ? 'Series' : 'Movie',
                    if (info.releaseDate != null &&
                        info.releaseDate!.length >= 4)
                      info.releaseDate!.substring(0, 4),
                    if (info.country != null) info.country!,
                    if (info.durationSeconds != null &&
                        info.durationSeconds! > 0)
                      '${info.durationSeconds! ~/ 60} min',
                    if (info.rating != null) 'IMDb ${info.rating}',
                    ...info.genres.take(4),
                    if (seasons.isNotEmpty)
                      '${seasons.length} season${seasons.length == 1 ? '' : 's'}',
                  ].join('   ·   '),
                  style: const TextStyle(color: Color(0xFFD5DCDE)),
                ),
                const SizedBox(height: 6),
                Text(
                  [
                    if (season > 0) 'Season $season · Episode $episode',
                    currentOffline == null
                        ? '${selected?.resolution ?? ''}p'
                        : 'Offline ${currentOffline!.resolution}p',
                    'Subtitles $captionLabel',
                  ].join('   ·   '),
                  style: const TextStyle(color: Color(0xFFBCC8C9)),
                ),
                if (info.description.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(info.description, style: const TextStyle(height: 1.45)),
                ],
                if ((detail?.cast ?? []).isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Cast',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final person in detail!.cast)
                        Chip(
                          avatar: person.image == null
                              ? null
                              : CircleAvatar(
                                  backgroundImage: CachedNetworkImageProvider(
                                    person.image!,
                                  ),
                                ),
                          label: Text(
                            person.character == null ||
                                    person.character!.isEmpty
                                ? person.name
                                : '${person.name} · ${person.character}',
                          ),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 28),
          SizedBox(
            width: 260,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  onPressed: currentOffline != null || downloadTask.active
                      ? null
                      : downloadCurrent,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(
                    currentOffline != null ? 'Downloaded' : 'Download',
                  ),
                ),
                const SizedBox(height: 8),
                if (controller != null &&
                    controller!.value.isInitialized &&
                    currentOffline == null)
                  OutlinedButton.icon(
                    onPressed: chooseQuality,
                    icon: const Icon(Icons.high_quality),
                    label: Text('Quality ${selected?.resolution ?? ''}p'),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    await widget.library.toggleBookmark(
                      detail?.title ?? widget.title,
                    );
                    if (mounted) setState(() {});
                  },
                  icon: Icon(
                    widget.library.bookmarks.containsKey(widget.title.path)
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                  ),
                  label: Text(
                    widget.library.bookmarks.containsKey(widget.title.path)
                        ? 'Bookmarked'
                        : 'Bookmark',
                  ),
                ),
                DownloadControls(task: downloadTask),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = controller;
    final info = detail?.title ?? widget.title;
    final seasons = detail?.seasons ?? [];
    final savedEpisodes = widget.library.downloads.values
        .where(
          (item) => item.title.path == widget.title.path && item.season > 0,
        )
        .toList();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF): () {
          if (!tvMode) toggleFullscreen();
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (fullscreen && !tvMode) {
            toggleFullscreen();
            return;
          }
          Navigator.of(context).maybePop();
        },
      },
      child: PopScope(
        canPop: !fullscreen || tvMode,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && fullscreen && !tvMode) toggleFullscreen();
        },
        child: Scaffold(
          appBar: fullscreen || tvMode
              ? null
              : AppBar(
                  title: Text(
                    info.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          body: MouseRegion(
            cursor: desktopWindow && !controlsVisible
                ? SystemMouseCursors.none
                : MouseCursor.defer,
            onHover: desktopWindow ? (_) => revealControls() : null,
            onEnter: desktopWindow ? (_) => revealControls() : null,
            child: Stack(
              children: [
                Positioned.fill(
                  child: desktopWindow
                      ? fullscreen
                            ? ColoredBox(
                                color: Colors.black,
                                child: videoSurface(player),
                              )
                            : SafeArea(
                                top: false,
                                child: desktopStage(player, info),
                              )
                      : expandedControls
                      ? expandedPlayer(player, info)
                      : SafeArea(
                          top: false,
                          child: desktopWindow
                              ? desktopStage(player, info)
                              : ListView(
                                  children: [
                                    videoSurface(player),
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        18,
                                        12,
                                        18,
                                        4,
                                      ),
                                      child: Row(
                                        children: [
                                          if (desktopWindow)
                                            FilledButton.icon(
                                              onPressed:
                                                  currentOffline != null ||
                                                      downloadTask.active
                                                  ? null
                                                  : downloadCurrent,
                                              icon: const Icon(
                                                Icons.download_outlined,
                                              ),
                                              label: Text(
                                                currentOffline != null
                                                    ? 'Downloaded'
                                                    : 'Download video + subtitles',
                                              ),
                                            )
                                          else
                                            Expanded(
                                              child: FilledButton.icon(
                                                onPressed:
                                                    currentOffline != null ||
                                                        downloadTask.active
                                                    ? null
                                                    : downloadCurrent,
                                                icon: const Icon(
                                                  Icons.download_outlined,
                                                ),
                                                label: Text(
                                                  currentOffline != null
                                                      ? 'Downloaded'
                                                      : 'Download video + subtitles',
                                                ),
                                              ),
                                            ),
                                          IconButton(
                                            tooltip:
                                                widget.library.bookmarks
                                                    .containsKey(
                                                      widget.title.path,
                                                    )
                                                ? 'Remove bookmark'
                                                : 'Bookmark',
                                            icon: Icon(
                                              widget.library.bookmarks
                                                      .containsKey(
                                                        widget.title.path,
                                                      )
                                                  ? Icons.bookmark
                                                  : Icons.bookmark_border,
                                            ),
                                            onPressed: () async {
                                              await widget.library
                                                  .toggleBookmark(
                                                    detail?.title ??
                                                        widget.title,
                                                  );
                                              if (mounted) setState(() {});
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (!desktopWindow)
                                      Padding(
                                        padding: const EdgeInsets.all(18),
                                        child: DownloadControls(
                                          task: downloadTask,
                                        ),
                                      ),
                                    if (!desktopWindow &&
                                        player != null &&
                                        player.value.isInitialized)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          18,
                                          10,
                                          18,
                                          0,
                                        ),
                                        child: Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            if (currentOffline == null)
                                              OutlinedButton.icon(
                                                onPressed: chooseQuality,
                                                icon: const Icon(
                                                  Icons.high_quality,
                                                ),
                                                label: Text(
                                                  'Quality ${selected?.resolution ?? ''}p',
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                    if (!desktopWindow)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          18,
                                          12,
                                          18,
                                          4,
                                        ),
                                        child: Text(
                                          info.title,
                                          style: const TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    if (!desktopWindow)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 18,
                                        ),
                                        child: Text(
                                          '${currentOffline == null ? '${selected?.resolution ?? ''}p' : 'Offline · ${currentOffline!.resolution}p'}  ·  Subtitles: $captionLabel',
                                          style: const TextStyle(
                                            color: Color(0xFFBCC8C9),
                                          ),
                                        ),
                                      ),
                                    if (!desktopWindow && season > 0)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          18,
                                          4,
                                          18,
                                          2,
                                        ),
                                        child: Text(
                                          'Season $season · Episode $episode',
                                          style: const TextStyle(
                                            color: Color(0xFFF2B86B),
                                          ),
                                        ),
                                      ),
                                    if (!desktopWindow &&
                                        info.description.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          18,
                                          12,
                                          18,
                                          8,
                                        ),
                                        child: Text(info.description),
                                      ),
                                    if (!desktopWindow &&
                                        info.kind != 'movie' &&
                                        (seasons.isNotEmpty ||
                                            savedEpisodes.isNotEmpty)) ...[
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                          18,
                                          20,
                                          18,
                                          8,
                                        ),
                                        child: Text(
                                          'Episodes',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleLarge,
                                        ),
                                      ),
                                      if (seasons.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 18,
                                          ),
                                          child: DropdownButton<int>(
                                            value:
                                                seasons.any(
                                                  (item) =>
                                                      item.number == season,
                                                )
                                                ? season
                                                : seasons.first.number,
                                            items: [
                                              for (final item in seasons)
                                                DropdownMenuItem(
                                                  value: item.number,
                                                  child: Text(
                                                    'Season ${item.number}',
                                                  ),
                                                ),
                                            ],
                                            onChanged: (value) {
                                              if (value != null) {
                                                changeEpisode(value, 1);
                                              }
                                            },
                                          ),
                                        ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 18,
                                        ),
                                        child: mobileEpisodeSelector(),
                                      ),
                                    ],
                                    const SizedBox(height: 28),
                                  ],
                                ),
                        ),
                ),
                if (captionPanel) ...[
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => captionPanel = false),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    bottom: 0,
                    width: () {
                      final width = MediaQuery.sizeOf(context).width;
                      final preferred = width * 0.3;
                      return preferred < 220
                          ? (width < 220 ? width : 220.0)
                          : preferred;
                    }(),
                    child: captionSidePanel(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String formatTime(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

class FixedCaptions extends ClosedCaptionFile {
  @override
  final List<Caption> captions;
  FixedCaptions(this.captions);
}

class SrtCaptions extends ClosedCaptionFile {
  @override
  final List<Caption> captions;
  SrtCaptions(String source) : captions = parse(source);

  static List<Caption> parse(String source) {
    final entries = <Caption>[];
    final blocks = source
        .replaceAll('\r\n', '\n')
        .replaceFirst('\uFEFF', '')
        .split(RegExp(r'\n\s*\n'));
    final timing = RegExp(
      r'(\d{2}):(\d{2}):(\d{2})[,\.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,\.](\d{3})',
    );
    for (final block in blocks) {
      final lines = block.trim().split('\n');
      final index = lines.indexWhere((line) => timing.hasMatch(line));
      if (index < 0 || index + 1 >= lines.length) continue;
      final match = timing.firstMatch(lines[index])!;
      Duration stamp(int start) => Duration(
        hours: int.parse(match[start]!),
        minutes: int.parse(match[start + 1]!),
        seconds: int.parse(match[start + 2]!),
        milliseconds: int.parse(match[start + 3]!),
      );
      entries.add(
        Caption(
          number: entries.length + 1,
          start: stamp(1),
          end: stamp(5),
          text: lines
              .skip(index + 1)
              .join('\n')
              .replaceAll(RegExp(r'<[^>]+>'), ''),
        ),
      );
    }
    return entries;
  }
}

import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'desktop.dart';
import 'download_controls.dart';
import 'library.dart';
import 'loading.dart';
import 'model.dart';
import 'nav_history.dart';
import 'notices.dart';
import 'player.dart';

void showError(BuildContext context, Object error) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
}

void openTitle(
  BuildContext context,
  MovieApi api,
  MovieLibrary library,
  MovieTitle title, {
  WatchEntry? resume,
}) {
  if (title.path.isEmpty) return;
  if (resume == null) {
    openPage(
      context,
      (_) => DetailScreen(api: api, library: library, path: title.path),
    );
    return;
  }
  final season = resume.season;
  final episode = resume.episode;
  final saved = library.downloads[viewingKey(title.path, season, episode)];
  openPage(
    context,
    (_) => PlayerScreen(
      api: api,
      library: library,
      title: title,
      season: season,
      episode: episode,
      offline: saved != null && File(saved.path).existsSync() ? saved : null,
    ),
  );
}

List<WatchEntry> latestWatchEntries(Iterable<WatchEntry> history) {
  final seen = <String>{};
  return history
      .toList()
      .reversed
      .where((entry) => seen.add(entry.title.path))
      .toList();
}

String artworkUrl(String source, int width) {
  final uri = Uri.tryParse(source);
  if (uri == null || uri.host != 'pbcdnw.aoneroom.com') return source;
  return uri
      .replace(
        queryParameters: {
          ...uri.queryParameters,
          'x-oss-process': 'image/resize,w_$width',
        },
      )
      .toString();
}

class Artwork extends StatelessWidget {
  final String? url;
  final int width;
  const Artwork({super.key, this.url, this.width = 420});

  @override
  Widget build(BuildContext context) => url == null || url!.isEmpty
      ? const ColoredBox(
          color: Color(0xFF273238),
          child: Icon(Icons.movie, size: 40),
        )
      : CachedNetworkImage(
          imageUrl: artworkUrl(url!, width),
          fit: BoxFit.cover,
          memCacheWidth: width,
          maxWidthDiskCache: width,
          fadeInDuration: const Duration(milliseconds: 120),
          placeholder: (_, _) => const ColoredBox(
            color: Color(0xFF273238),
            child: Center(child: Icon(Icons.movie_outlined, size: 32)),
          ),
          errorWidget: (_, _, _) => const ColoredBox(
            color: Color(0xFF273238),
            child: Icon(Icons.movie, size: 40),
          ),
        );
}

class DownloadArtwork extends StatelessWidget {
  final SavedDownload? download;
  final MovieTitle title;
  const DownloadArtwork({super.key, required this.title, this.download});

  @override
  Widget build(BuildContext context) {
    final path = download?.thumbnailPath;
    if (path == null || !File(path).existsSync()) {
      return Artwork(url: title.poster ?? title.backdrop);
    }
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Artwork(url: title.poster ?? title.backdrop),
    );
  }
}

class Poster extends StatefulWidget {
  final MovieTitle title;
  final VoidCallback onTap;
  final double width;
  const Poster({
    super.key,
    required this.title,
    required this.onTap,
    this.width = 130,
  });
  @override
  State<Poster> createState() => _PosterState();
}

class _PosterState extends State<Poster> {
  bool hover = false;

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final width = widget.width;
    return MouseRegion(
      onEnter: (_) {
        if (isDesktopWindow) setState(() => hover = true);
      },
      onExit: (_) {
        if (hover) setState(() => hover = false);
      },
      child: AnimatedScale(
        scale: hover ? 1.045 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: SizedBox(
          width: width,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(12),
            focusColor: const Color(0x66F2B86B),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AspectRatio(
                    aspectRatio: 2 / 3,
                    child: Artwork(url: title.poster),
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  title.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class TitleGrid extends StatelessWidget {
  final List<MovieTitle> items;
  final void Function(MovieTitle) onTap;
  const TitleGrid({super.key, required this.items, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final columns = gridColumns(
            context,
            width: constraints.crossAxisExtent,
          );
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              crossAxisSpacing: 14,
              mainAxisSpacing: 18,
              childAspectRatio: 0.56,
            ),
            itemCount: items.length,
            itemBuilder: (_, index) =>
                Poster(title: items[index], onTap: () => onTap(items[index])),
          );
        },
      ),
    );
  }
}

class ScreenHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onRefresh;
  const ScreenHeader(this.title, {super.key, this.onRefresh});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 17, 12, 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
        ),
        if (onRefresh != null)
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: onRefresh,
          ),
        if (MediaQuery.sizeOf(context).width < wideLayoutBreakpoint)
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
      ],
    ),
  );
}

class HomeScreen extends StatefulWidget {
  final MovieApi api;
  final MovieLibrary library;
  const HomeScreen({super.key, required this.api, required this.library});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late Future<MovieHome> data = widget.api.home();
  @override
  void initState() {
    super.initState();
    widget.library.addListener(refreshHistory);
  }

  @override
  void dispose() {
    widget.library.removeListener(refreshHistory);
    super.dispose();
  }

  void refreshHistory() {
    if (mounted) setState(() {});
  }

  void reload() {
    setState(() {
      data = widget.api.home();
    });
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) reload();
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () async {
      reload();
      try {
        await data;
      } catch (_) {
        // The FutureBuilder displays refresh errors with a retry action.
      }
    },
    child: FutureBuilder<MovieHome>(
      future: data,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done ||
            !snapshot.hasData) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              ScreenHeader('MovieBox', onRefresh: reload),
              SizedBox(
                height: 400,
                child: Center(
                  child:
                      snapshot.connectionState == ConnectionState.done &&
                          snapshot.hasError
                      ? ErrorPanel(error: snapshot.error!, retry: reload)
                      : const MovieBoxLoader(label: 'Loading your home'),
                ),
              ),
            ],
          );
        }
        final home = snapshot.data!;
        final history = latestWatchEntries(widget.library.history.values);
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            ScreenHeader('MovieBox', onRefresh: reload),
            PopularCarousel(
              titles: home.sections
                  .where(
                    (section) =>
                        section.title.toLowerCase().contains('popular'),
                  )
                  .expand((section) => section.items)
                  .take(6)
                  .toList(),
              fallback: home.banners,
              onTap: (title) =>
                  openTitle(context, widget.api, widget.library, title),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final category in [
                    ('movies', 'Movies'),
                    ('series', 'Series'),
                    ('animation', 'Anime'),
                  ])
                    ActionChip(
                      label: Text(category.$2),
                      onPressed: () => openPage(
                        context,
                        (_) => Scaffold(
                          appBar: AppBar(title: Text(category.$2)),
                          body: CatalogScreen(
                            api: widget.api,
                            library: widget.library,
                            name: category.$1,
                            label: category.$2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (history.isNotEmpty)
              ContinueRow(
                history,
                widget.library,
                (entry) => openTitle(
                  context,
                  widget.api,
                  widget.library,
                  entry.title,
                  resume: entry,
                ),
              ),
            for (final section in home.sections)
              if (section.items.isNotEmpty)
                MovieRow(
                  section.title,
                  section.items,
                  (title) =>
                      openTitle(context, widget.api, widget.library, title),
                ),
          ],
        );
      },
    ),
  );
}

class PopularCarousel extends StatefulWidget {
  final List<MovieTitle> titles, fallback;
  final void Function(MovieTitle) onTap;
  const PopularCarousel({
    super.key,
    required this.titles,
    required this.fallback,
    required this.onTap,
  });
  @override
  State<PopularCarousel> createState() => _PopularCarouselState();
}

class _PopularCarouselState extends State<PopularCarousel> {
  int index = 0;
  final pages = PageController();

  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final titles = widget.titles.isEmpty ? widget.fallback : widget.titles;
    if (titles.isEmpty) return const SizedBox.shrink();
    final desktop = MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint;
    final height = desktop ? 380.0 : 265.0;
    return Column(
      children: [
        SizedBox(
          height: height,
          child: Stack(
            children: [
              PageView.builder(
                controller: pages,
                itemCount: titles.length,
                onPageChanged: (value) => setState(() => index = value),
                itemBuilder: (context, page) {
                  final title = titles[page];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: InkWell(
                      onTap: () => widget.onTap(title),
                      borderRadius: BorderRadius.circular(18),
                      focusColor: const Color(0x66F2B86B),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Stack(
                          alignment: Alignment.bottomLeft,
                          children: [
                            SizedBox.expand(
                              child: Artwork(
                                url: title.backdrop ?? title.poster,
                                width: desktop ? 1600 : 900,
                              ),
                            ),
                            Container(
                              height: 150,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.transparent,
                                    Color(0xEE101519),
                                  ],
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(18),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'POPULAR NOW',
                                    style: TextStyle(
                                      color: Color(0xFFF2B86B),
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 2,
                                    ),
                                  ),
                                  Text(
                                    title.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 25,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Text('Watch now  ›'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (desktop)
                for (final (alignment, icon, target) in [
                  (Alignment.centerLeft, Icons.chevron_left, index - 1),
                  (Alignment.centerRight, Icons.chevron_right, index + 1),
                ])
                  if (target >= 0 && target < titles.length)
                    Align(
                      alignment: alignment,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 26),
                        child: _CarouselArrow(
                          icon: icon,
                          onPressed: () => pages.animateToPage(
                            target,
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          ),
                        ),
                      ),
                    ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < titles.length; i++)
                Container(
                  width: i == index ? 18 : 6,
                  height: 6,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: i == index
                        ? const Color(0xFFF2B86B)
                        : Colors.white38,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CarouselArrow extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  const _CarouselArrow({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xCC101519),
    shape: const CircleBorder(),
    child: IconButton(
      tooltip: icon == Icons.chevron_left ? 'Previous' : 'Next',
      onPressed: onPressed,
      icon: Icon(icon),
    ),
  );
}

class ContinueRow extends StatelessWidget {
  final List<WatchEntry> entries;
  final MovieLibrary library;
  final void Function(WatchEntry) onTap;
  const ContinueRow(this.entries, this.library, this.onTap, {super.key});
  @override
  Widget build(BuildContext context) {
    final width = posterWidth(context);
    final thumbHeight = width * 1.13;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 14, 18, 12),
          child: Text(
            'Continue Watching',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          height: thumbHeight + 78,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            itemCount: entries.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, index) {
              final entry = entries[index];
              final progress = entry.durationSeconds <= 0
                  ? 0.0
                  : (entry.positionSeconds / entry.durationSeconds).clamp(
                      0.0,
                      1.0,
                    );
              return SizedBox(
                width: width,
                child: InkWell(
                  onTap: () => onTap(entry),
                  borderRadius: BorderRadius.circular(10),
                  focusColor: const Color(0x66F2B86B),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(
                              height: thumbHeight,
                              width: width,
                              child: DownloadArtwork(
                                title: entry.title,
                                download: library.downloads[entry.key],
                              ),
                            ),
                          ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Material(
                              color: const Color(0xCC101519),
                              shape: const CircleBorder(),
                              child: IconButton(
                                tooltip: 'Remove from continue watching',
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    library.removeHistory(entry.key),
                                icon: const Icon(Icons.close, size: 16),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                        backgroundColor: const Color(0xFF343D41),
                        color: const Color(0xFFDF4B47),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        entry.title.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        entry.season > 0
                            ? 'S${entry.season} E${entry.episode} · ${entry.positionSeconds ~/ 60} min'
                            : '${entry.positionSeconds ~/ 60} min watched',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFBCC8C9),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class MovieRow extends StatelessWidget {
  final String heading;
  final List<MovieTitle> titles;
  final void Function(MovieTitle) onTap;
  const MovieRow(this.heading, this.titles, this.onTap, {super.key});
  @override
  Widget build(BuildContext context) {
    final width = posterWidth(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
          child: Text(
            heading,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        SizedBox(
          height: width * 1.5 + 56,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            itemCount: titles.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, index) => Poster(
              title: titles[index],
              width: width,
              onTap: () => onTap(titles[index]),
            ),
          ),
        ),
      ],
    );
  }
}

class ErrorPanel extends StatelessWidget {
  final Object error;
  final VoidCallback retry;
  const ErrorPanel({super.key, required this.error, required this.retry});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.wifi_off, size: 42),
        const SizedBox(height: 12),
        Text('$error', textAlign: TextAlign.center),
        TextButton(onPressed: retry, child: const Text('Try again')),
        TextButton(
          onPressed: () => Navigator.pushNamed(context, '/settings'),
          child: const Text('Server settings'),
        ),
      ],
    ),
  );
}

class CatalogScreen extends StatefulWidget {
  final MovieApi api;
  final MovieLibrary library;
  final String name, label;
  const CatalogScreen({
    super.key,
    required this.api,
    required this.library,
    required this.name,
    required this.label,
  });
  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  final items = <MovieTitle>[];
  int? next = 1;
  bool loading = false;
  Object? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant CatalogScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || oldWidget.name != widget.name) {
      reload();
    }
  }

  Future<void> reload() {
    generation++;
    setState(() {
      items.clear();
      next = 1;
      loading = false;
    });
    return load();
  }

  Future<void> load() async {
    if (loading || next == null) return;
    final page = next!;
    final serial = generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.catalog(widget.name, page);
      if (!mounted || serial != generation) return;
      setState(() {
        items.addAll(result.items);
        next = result.next;
      });
    } catch (e) {
      if (mounted && serial == generation) setState(() => error = e);
    } finally {
      if (mounted && serial == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: reload,
    child: CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: ScreenHeader(widget.label, onRefresh: reload),
        ),
        if (items.isNotEmpty)
          TitleGrid(
            items: items,
            onTap: (title) =>
                openTitle(context, widget.api, widget.library, title),
          ),
        if (items.isEmpty && error == null && !loading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('No titles found.')),
            ),
          ),
        if (error != null)
          SliverToBoxAdapter(
            child: ErrorPanel(error: error!, retry: load),
          ),
        if (loading)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: MovieBoxLoader(
                  label: items.isEmpty
                      ? 'Loading titles'
                      : 'Loading more titles',
                  compact: items.isNotEmpty,
                ),
              ),
            ),
          ),
        if (!loading && next != null && error == null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: OutlinedButton(
                onPressed: load,
                child: const Text('Load more'),
              ),
            ),
          ),
      ],
    ),
  );
}

class SearchScreen extends StatefulWidget {
  final MovieApi api;
  final MovieLibrary library;
  final bool active;
  const SearchScreen({
    super.key,
    required this.api,
    required this.library,
    this.active = true,
  });
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final text = TextEditingController();
  final searchFocus = FocusNode(debugLabel: 'Search input');
  final items = <MovieTitle>[];
  List<String> hints = [];
  int? next;
  bool loading = false;
  bool hasSearched = false;
  Object? error;
  Timer? debounce;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    widget.api
        .popular()
        .then((value) {
          if (mounted && text.text.isEmpty) setState(() => hints = value);
        })
        .catchError((_) {});
  }

  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) changed(text.text);
    if (widget.active &&
        !oldWidget.active &&
        MediaQuery.sizeOf(context).width >= wideLayoutBreakpoint) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) searchFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    text.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void changed(String query) {
    debounce?.cancel();
    generation++;
    final serial = generation;
    setState(() {
      items.clear();
      next = null;
      loading = false;
      hasSearched = false;
      error = null;
      hints = [];
    });
    if (query.trim().isEmpty) {
      widget.api
          .popular()
          .then((value) {
            if (mounted && serial == generation) setState(() => hints = value);
          })
          .catchError((_) {});
      return;
    }
    debounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || serial != generation) return;
      setState(() => next = 1);
      load();
    });
  }

  Future<void> submit([String? term]) async {
    if (term != null) {
      text.text = term;
      text.selection = TextSelection.collapsed(offset: term.length);
    }
    final query = text.text.trim();
    if (query.isEmpty) return;
    debounce?.cancel();
    generation++;
    setState(() {
      items.clear();
      hints = [];
      next = 1;
      loading = false;
      hasSearched = false;
      error = null;
    });
    FocusScope.of(context).unfocus();
    await load();
  }

  Future<void> load() async {
    if (loading || next == null) return;
    final page = next!;
    final serial = generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.api.search(text.text.trim(), page);
      if (!mounted || serial != generation) return;
      setState(() {
        items.addAll(result.items);
        next = result.next;
        hasSearched = true;
      });
    } catch (e) {
      if (mounted && serial == generation) setState(() => error = e);
    } finally {
      if (mounted && serial == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverToBoxAdapter(
        child: Column(
          children: [
            const ScreenHeader('Search'),
            ContentFrame(
              maxWidth: 1120,
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        focusNode: searchFocus,
                        controller: text,
                        textInputAction: TextInputAction.search,
                        onChanged: changed,
                        onSubmitted: (_) => submit(),
                        decoration: InputDecoration(
                          hintText: 'Find a movie or series',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon:
                              MediaQuery.sizeOf(context).width >=
                                  wideLayoutBreakpoint
                              ? null
                              : IconButton(
                                  tooltip: 'Search',
                                  icon: const Icon(Icons.arrow_forward),
                                  onPressed: submit,
                                ),
                        ),
                      ),
                    ),
                    if (MediaQuery.sizeOf(context).width >=
                        wideLayoutBreakpoint) ...[
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: submit,
                        icon: const Icon(Icons.search),
                        label: const Text('Search'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          text.clear();
                          changed('');
                        },
                        child: const Text('Clear'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (hints.isNotEmpty)
              ContentFrame(
                maxWidth: 1120,
                alignment: Alignment.topLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(18, 20, 18, 4),
                      child: Text(
                        'POPULAR SEARCHES',
                        style: TextStyle(
                          color: Color(0xFFF2B86B),
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                    for (final hint in hints.take(10))
                      ListTile(
                        title: Text(hint),
                        trailing: const Icon(Icons.north_west, size: 18),
                        onTap: () => submit(hint),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      if (items.isNotEmpty)
        TitleGrid(
          items: items,
          onTap: (title) =>
              openTitle(context, widget.api, widget.library, title),
        ),
      if (hasSearched &&
          !loading &&
          error == null &&
          text.text.isNotEmpty &&
          items.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(30),
            child: Center(child: Text('No results found.')),
          ),
        ),
      if (error != null)
        SliverToBoxAdapter(
          child: SizedBox(
            height: 250,
            child: ErrorPanel(error: error!, retry: load),
          ),
        ),
      if (loading)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: MovieBoxLoader(
                label: items.isEmpty
                    ? 'Searching titles'
                    : 'Loading more titles',
                compact: items.isNotEmpty,
              ),
            ),
          ),
        ),
      if (!loading && next != null && error == null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton(
              onPressed: load,
              child: const Text('Load more'),
            ),
          ),
        ),
    ],
  );
}

class DetailScreen extends StatefulWidget {
  final MovieApi api;
  final MovieLibrary library;
  final String path;
  const DetailScreen({
    super.key,
    required this.api,
    required this.library,
    required this.path,
  });
  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  late Future<MovieDetail> future;
  int season = 0, episode = 0;
  bool busy = false;
  String? downloadLabel;
  bool showEpisodeSearch = false;
  final episodeSearch = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.library.addListener(refreshDownloads);
    future = loadDetail();
  }

  void refreshDownloads() {
    if (mounted) setState(() {});
  }

  Future<MovieDetail> loadDetail() async {
    final value = await widget.api.detail(widget.path);
    if (mounted && season == 0 && episode == 0 && value.seasons.isNotEmpty) {
      final recent = latestWatchEntries(widget.library.history.values)
          .where((entry) => entry.title.path == widget.path)
          .firstOrNull;
      setState(() {
        season = recent?.season ?? value.seasons.first.number;
        episode = recent?.episode ?? 1;
      });
    }
    return value;
  }

  @override
  void dispose() {
    episodeSearch.dispose();
    widget.library.removeListener(refreshDownloads);
    super.dispose();
  }

  List<(int, int)> visibleEpisodes(MovieDetail detail) {
    final selectedSeason = detail.seasons.any((item) => item.number == season)
        ? season
        : detail.seasons.first.number;
    final all = [
      for (final item in detail.seasons)
        for (var number = 1; number <= item.episodes; number++)
          (item.number, number),
    ];
    final query = episodeSearch.text.trim().toLowerCase();
    if (!showEpisodeSearch || query.isEmpty) {
      return all.where((item) => item.$1 == selectedSeason).toList();
    }
    final explicit = RegExp(r's(?:eason)?\s*(\d+)\s*e(?:p(?:isode)?)?\s*(\d+)')
        .firstMatch(query);
    if (explicit != null) {
      final wantedSeason = int.parse(explicit.group(1)!);
      final wantedEpisode = int.parse(explicit.group(2)!);
      return all
          .where((item) => item.$1 == wantedSeason && item.$2 == wantedEpisode)
          .toList();
    }
    final number = int.tryParse(query);
    if (number != null) {
      return all.where((item) => item.$2 == number).toList();
    }
    return all.where((item) {
      final label = 'season ${item.$1} episode ${item.$2}';
      return label.contains(query);
    }).toList();
  }

  Future<void> play(MovieTitle title, {SavedDownload? offline}) async {
    openPage(
      context,
      (_) => PlayerScreen(
        api: widget.api,
        library: widget.library,
        title: title,
        season: season,
        episode: episode,
        offline: offline,
        resume: false,
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> download(MovieTitle title) async {
    if (busy) return;
    final requestedSeason = season;
    final requestedEpisode = episode;
    final task = widget.library.taskFor(
      title,
      requestedSeason,
      requestedEpisode,
    );
    if (task.active) return;
    setState(() {
      busy = true;
      downloadLabel = 'Getting download options';
    });
    try {
      final playback = await widget.api.playback(
        title.path,
        requestedSeason,
        requestedEpisode,
      );
      if (!mounted) return;
      final choices = playback.streams
          .where((s) => s.format.toUpperCase() == 'MP4' && !s.locked)
          .toList();
      if (choices.isEmpty) {
        throw ApiException('No downloadable MP4 stream is available.');
      }
      setState(() => downloadLabel = null);
      final selected = await showModalBottomSheet<MovieStream>(
        context: context,
        builder: (_) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('Download quality')),
              for (final stream in choices.reversed)
                ListTile(
                  title: Text('${stream.resolution}p'),
                  subtitle: Text(
                    stream.size == null
                        ? 'MP4'
                        : '${(stream.size! / 1048576).round()} MB · MP4',
                  ),
                  onTap: () => Navigator.pop(context, stream),
                ),
            ],
          ),
        ),
      );
      if (selected == null || !mounted) return;
      setState(() => downloadLabel = 'Preparing download');
      MovieCaption? caption;
      try {
        final options = await widget.api.captions(
          title.path,
          selected.id,
          requestedSeason,
          requestedEpisode,
        );
        for (final option in options) {
          if (option.language.toLowerCase().startsWith('en')) {
            caption = option;
            break;
          }
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() => downloadLabel = null);
      final saved = await task.start(
        widget.api,
        widget.library,
        title,
        requestedSeason,
        requestedEpisode,
        selected,
        caption,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              saved == null
                  ? 'Download started. You can leave this screen; manage it in Downloads.'
                  : 'Already downloaded. To change quality, delete the saved copy from Downloads first.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          downloadLabel = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      SingleActivator(LogicalKeyboardKey.escape): () {
        Navigator.of(context).maybePop();
      },
    },
    child: Focus(
      autofocus: true,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            MediaQuery.sizeOf(context).width >= splitLayoutBreakpoint
                ? 'Movie Box'
                : 'Title details',
          ),
        ),
        body: SafeArea(
          top: false,
          child: FutureBuilder<MovieDetail>(
            future: future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done ||
                  !snapshot.hasData) {
                return Center(
                  child:
                      snapshot.connectionState == ConnectionState.done &&
                          snapshot.hasError
                      ? ErrorPanel(
                          error: snapshot.error!,
                          retry: () => setState(() {
                            future = loadDetail();
                          }),
                        )
                      : const MovieBoxLoader(label: 'Loading details'),
                );
              }
              final detail = snapshot.data!;
              final title = detail.title;
              final task = widget.library.taskFor(title, season, episode);
              final saved = widget
                  .library
                  .downloads[viewingKey(title.path, season, episode)];
              final wide =
                  MediaQuery.sizeOf(context).width >= splitLayoutBreakpoint;
              return ListView(
                children: [
                  if (wide)
                    ContentFrame(
                      maxWidth: 1140,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: SizedBox(
                            height: 380,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Artwork(
                                  url: title.backdrop ?? title.poster,
                                  width: 1600,
                                ),
                                const DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Color(0x22000000),
                                        Color(0xF0101519),
                                      ],
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(22),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(12),
                                        child: SizedBox(
                                          width: 150,
                                          child: AspectRatio(
                                            aspectRatio: 2 / 3,
                                            child: Artwork(
                                              url:
                                                  title.poster ??
                                                  title.backdrop,
                                              width: 420,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 22),
                                      Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.end,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              title.title,
                                              style: const TextStyle(
                                                fontSize: 34,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              [
                                                title.kind.toUpperCase(),
                                                if (title.rating != null)
                                                  'IMDb ${title.rating}',
                                                ...title.genres.take(3),
                                              ].join('  ·  '),
                                              style: const TextStyle(
                                                color: Color(0xFFD5DCDE),
                                              ),
                                            ),
                                            const SizedBox(height: 14),
                                            Row(
                                              children: [
                                                FilledButton.icon(
                                                  onPressed:
                                                      title.available &&
                                                          (detail
                                                                  .seasons
                                                                  .isEmpty ||
                                                              episode > 0)
                                                      ? () => play(
                                                          title,
                                                          offline:
                                                              saved != null &&
                                                                  File(
                                                                    saved.path,
                                                                  ).existsSync()
                                                              ? saved
                                                              : null,
                                                        )
                                                      : null,
                                                  icon: const Icon(
                                                    Icons.play_arrow,
                                                  ),
                                                  label: const Text('Play'),
                                                ),
                                                const SizedBox(width: 10),
                                                OutlinedButton.icon(
                                                  onPressed:
                                                      busy ||
                                                          task.active ||
                                                          !title.available ||
                                                          (detail
                                                                  .seasons
                                                                  .isNotEmpty &&
                                                              episode == 0)
                                                      ? null
                                                      : () => download(title),
                                                  icon: const Icon(
                                                    Icons.download_outlined,
                                                  ),
                                                  label: Text(
                                                    downloadLabel ?? 'Download',
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                IconButton(
                                                  tooltip:
                                                      widget.library.bookmarks
                                                          .containsKey(
                                                            title.path,
                                                          )
                                                      ? 'Remove bookmark'
                                                      : 'Bookmark show',
                                                  onPressed: () => widget
                                                      .library
                                                      .toggleBookmark(title),
                                                  icon: Icon(
                                                    widget.library.bookmarks
                                                            .containsKey(
                                                              title.path,
                                                            )
                                                        ? Icons.bookmark
                                                        : Icons.bookmark_border,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    SizedBox(
                      height: 230,
                      child: Artwork(
                        url: title.backdrop ?? title.poster,
                        width: 1080,
                      ),
                    ),
                  ContentFrame(
                    maxWidth: 1140,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (wide)
                                  Text(
                                    title.description.isEmpty
                                        ? 'No synopsis available.'
                                        : title.description,
                                  )
                                else
                                  Text(
                                    title.title,
                                    style: const TextStyle(
                                      fontSize: 29,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                if (!wide) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    [
                                      title.kind.toUpperCase(),
                                      if (title.rating != null)
                                        'IMDb ${title.rating}',
                                      ...title.genres.take(3),
                                    ].join('  ·  '),
                                    style: const TextStyle(
                                      color: Color(0xFFBCC8C9),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    title.description.isEmpty
                                        ? 'No synopsis available.'
                                        : title.description,
                                  ),
                                  const SizedBox(height: 20),
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: wide ? 320 : double.infinity,
                                    ),
                                    child: FilledButton.icon(
                                      onPressed:
                                          title.available &&
                                              (detail.seasons.isEmpty ||
                                                  episode > 0)
                                          ? () => play(
                                              title,
                                              offline:
                                                  saved != null &&
                                                      File(saved.path)
                                                          .existsSync()
                                                  ? saved
                                                  : null,
                                            )
                                          : null,
                                      icon: const Icon(Icons.play_arrow),
                                      label: const Text('Play'),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  OutlinedButton.icon(
                                    onPressed: () =>
                                        widget.library.toggleBookmark(title),
                                    icon: Icon(
                                      widget.library.bookmarks.containsKey(
                                            title.path,
                                          )
                                          ? Icons.bookmark
                                          : Icons.bookmark_border,
                                    ),
                                    label: Text(
                                      widget.library.bookmarks.containsKey(
                                            title.path,
                                          )
                                          ? 'Bookmarked'
                                          : 'Bookmark show',
                                    ),
                                  ),
                                  if (detail.seasons.isNotEmpty && episode == 0)
                                    const Text(
                                      'Choose an episode to play or download.',
                                    ),
                                  const SizedBox(height: 7),
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: wide ? 320 : double.infinity,
                                    ),
                                    child: OutlinedButton.icon(
                                      onPressed:
                                          busy ||
                                              task.active ||
                                              !title.available ||
                                              (detail.seasons.isNotEmpty &&
                                                  episode == 0)
                                          ? null
                                          : () => download(title),
                                      icon: downloadLabel == null
                                          ? const Icon(Icons.download_outlined)
                                          : const SizedBox.shrink(),
                                      label: downloadLabel == null
                                          ? const Text('Download MP4')
                                          : MovieBoxLoader(
                                              label: downloadLabel!,
                                              compact: true,
                                            ),
                                    ),
                                  ),
                                  if (saved != null &&
                                      File(saved.path).existsSync())
                                    TextButton.icon(
                                      onPressed: () =>
                                          play(title, offline: saved),
                                      icon: const Icon(Icons.offline_pin),
                                      label: Text(
                                        'Play downloaded ${saved.resolution}p',
                                      ),
                                    ),
                                  DownloadControls(task: task),
                                ],
                                if (detail.seasons.isNotEmpty) ...[
                                  const SizedBox(height: 20),
                                  Row(
                                    children: [
                                      const Expanded(
                                        child: Text(
                                          'Episodes',
                                          style: TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Find episode',
                                        icon: Icon(
                                          showEpisodeSearch
                                              ? Icons.close
                                              : Icons.search,
                                        ),
                                        onPressed: () => setState(() {
                                          showEpisodeSearch =
                                              !showEpisodeSearch;
                                          if (!showEpisodeSearch) {
                                            episodeSearch.clear();
                                          }
                                        }),
                                      ),
                                    ],
                                  ),
                                  if (showEpisodeSearch)
                                    TextField(
                                      controller: episodeSearch,
                                      keyboardType: TextInputType.text,
                                      decoration: const InputDecoration(
                                        hintText: 'Episode number, or S2 E4',
                                        prefixIcon: Icon(Icons.search),
                                        isDense: true,
                                      ),
                                      onChanged: (_) => setState(() {}),
                                    ),
                                  const SizedBox(height: 8),
                                  DropdownButton<int>(
                                    value:
                                        detail.seasons.any(
                                          (s) => s.number == season,
                                        )
                                        ? season
                                        : detail.seasons.first.number,
                                    items: [
                                      for (final s in detail.seasons)
                                        DropdownMenuItem(
                                          value: s.number,
                                          child: Text('Season ${s.number}'),
                                        ),
                                    ],
                                    onChanged: (value) => setState(() {
                                      season = value!;
                                      episode = 1;
                                    }),
                                  ),
                                  Builder(
                                    builder: (context) {
                                      final matches = visibleEpisodes(detail);
                                      final searching =
                                          showEpisodeSearch &&
                                          episodeSearch.text.trim().isNotEmpty;
                                      if (matches.isEmpty) {
                                        return const Padding(
                                          padding: EdgeInsets.only(top: 8),
                                          child: Text(
                                            'No episode matches that.',
                                          ),
                                        );
                                      }
                                      return Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          for (final item in matches)
                                            ChoiceChip(
                                              label: Text(
                                                searching
                                                    ? 'S${item.$1} E${item.$2}'
                                                    : '${item.$2}',
                                              ),
                                              selected:
                                                  episode == item.$2 &&
                                                  season == item.$1,
                                              onSelected: (_) => setState(() {
                                                season = item.$1;
                                                episode = item.$2;
                                              }),
                                            ),
                                        ],
                                      );
                                    },
                                  ),
                                ],
                                if (detail.dubs.isNotEmpty) ...[
                                  const SizedBox(height: 18),
                                  const Text(
                                    'Other audio versions',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  for (final dub in detail.dubs)
                                    ListTile(
                                      title: Text(dub.title),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => openTitle(
                                        context,
                                        widget.api,
                                        widget.library,
                                        dub,
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  FutureBuilder<MoviePage>(
                    future: widget.api.recommendations(widget.path),
                    builder: (_, result) =>
                        result.hasData && result.data!.items.isNotEmpty
                        ? MovieRow(
                            'You might also like',
                            result.data!.items,
                            (item) => openTitle(
                              context,
                              widget.api,
                              widget.library,
                              item,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class LibraryScreen extends StatefulWidget {
  final MovieApi api;
  final MovieLibrary library;
  const LibraryScreen({super.key, required this.api, required this.library});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    widget.library.addListener(refresh);
  }

  @override
  void dispose() {
    widget.library.removeListener(refresh);
    super.dispose();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final downloads = widget.library.downloads.values
        .toList()
        .reversed
        .toList();
    final history = latestWatchEntries(widget.library.history.values);
    return ListView(
      children: [
        const ScreenHeader('Downloads'),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
          child: Text(
            isDesktopWindow
                ? 'Keep MovieBox running while downloading. You can minimize the window. '
                      'If you close the app, reopen it to recover interrupted transfers.'
                : 'Downloads continue in the background. Android notifications show progress. '
                      'If your device stops a transfer, reopen MovieBox to recover it.',
          ),
        ),
        for (final task in widget.library.downloadTasks.values)
          if (!task.complete &&
              !task.cancelled &&
              (task.active || task.error != null))
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFF1D2529),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${task.title.title}${task.season > 0 ? ' · S${task.season} E${task.episode}' : ''}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      DownloadControls(task: task),
                    ],
                  ),
                ),
              ),
            ),
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 8, 18, 4),
          child: Text(
            'Saved on this device',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        if (downloads.isEmpty)
          const ListTile(
            title: Text('No downloads yet.'),
            subtitle: Text('Saved videos stay on this device.'),
          ),
        for (final entry in downloads)
          ListTile(
            leading: SizedBox(
              width: 54,
              height: 68,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: DownloadArtwork(title: entry.title, download: entry),
              ),
            ),
            title: Text(entry.title.title),
            subtitle: Text(
              '${entry.resolution}p${entry.season > 0 ? ' · S${entry.season} E${entry.episode}' : ''} · ${entry.subtitlePath != null && File(entry.subtitlePath!).existsSync() ? 'Subtitles saved' : 'No subtitles'}',
            ),
            onTap: () => openPage(
              context,
              (_) => PlayerScreen(
                api: widget.api,
                library: widget.library,
                title: entry.title,
                season: entry.season,
                episode: entry.episode,
                offline: entry,
              ),
            ),
            trailing: IconButton(
              tooltip: 'Delete download',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Delete download?'),
                    content: Text(entry.title.title),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (yes == true) await widget.library.removeDownload(entry);
              },
            ),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 24, 18, 4),
          child: Text(
            'Continue Watching',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
        ),
        if (history.isEmpty)
          const ListTile(
            title: Text('Nothing in progress yet.'),
            subtitle: Text('Your place is saved as you watch.'),
          ),
        for (final entry in history)
          ListTile(
            leading: SizedBox(
              width: 54,
              height: 68,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: DownloadArtwork(
                  title: entry.title,
                  download: widget.library.downloads[entry.key],
                ),
              ),
            ),
            title: Text(entry.title.title),
            subtitle: Text(
              '${entry.season > 0 ? 'S${entry.season} E${entry.episode} · ' : ''}${Duration(seconds: entry.positionSeconds).inMinutes} min watched',
            ),
            trailing: IconButton(
              tooltip: 'Remove from continue watching',
              icon: const Icon(Icons.close),
              onPressed: () => widget.library.removeHistory(entry.key),
            ),
            onTap: () {
              final saved = widget.library.downloads[entry.key];
              if (saved != null && File(saved.path).existsSync()) {
                openPage(
                  context,
                  (_) => PlayerScreen(
                    api: widget.api,
                    library: widget.library,
                    title: entry.title,
                    season: entry.season,
                    episode: entry.episode,
                    offline: saved,
                  ),
                );
              } else {
                openPage(
                  context,
                  (_) => PlayerScreen(
                    api: widget.api,
                    library: widget.library,
                    title: entry.title,
                    season: entry.season,
                    episode: entry.episode,
                  ),
                );
              }
            },
          ),
      ],
    );
  }
}

class BookmarksScreen extends StatefulWidget {
  final MovieApi api;
  final MovieLibrary library;
  const BookmarksScreen({super.key, required this.api, required this.library});
  @override
  State<BookmarksScreen> createState() => _BookmarksScreenState();
}

class _BookmarksScreenState extends State<BookmarksScreen> {
  @override
  void initState() {
    super.initState();
    widget.library.addListener(refresh);
  }

  @override
  void dispose() {
    widget.library.removeListener(refresh);
    super.dispose();
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final titles = widget.library.bookmarks.values.toList().reversed.toList();
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: ScreenHeader('Library')),
        if (titles.isEmpty)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No bookmarks yet. Save titles from the watch page to find them here.',
              ),
            ),
          ),
        if (titles.isNotEmpty)
          TitleGrid(
            items: titles,
            onTap: (title) =>
                openTitle(context, widget.api, widget.library, title),
          ),
      ],
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final MovieApi api;
  final MovieLibrary library;
  final VoidCallback onSaved;
  final bool standalone;
  const SettingsScreen({
    super.key,
    required this.api,
    required this.library,
    required this.onSaved,
    this.standalone = false,
  });
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final address = TextEditingController();
  late final token = TextEditingController(text: widget.library.token);
  bool testing = false;
  bool saving = false;
  @override
  void dispose() {
    address.dispose();
    token.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (testing) return;
    final enteredAddress = address.text.trim();
    final raw = enteredAddress.isEmpty ? widget.library.server : enteredAddress;
    final accessToken = token.text.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty) {
      showError(context, 'Enter a full http:// or https:// server address.');
      return;
    }
    setState(() {
      testing = true;
      saving = false;
    });
    final candidate = MovieApi(baseUrl: raw, token: accessToken);
    try {
      await candidate.ping();
      if (!mounted) return;
      setState(() => saving = true);
      await widget.library.configure(raw, accessToken);
      if (!mounted) return;
      address.clear();
      widget.onSaved();
      if (mounted) {
        if (widget.standalone) {
          Navigator.pop(context);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Server connection saved.')),
          );
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      candidate.close();
      if (mounted) {
        setState(() {
          testing = false;
          saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = ContentFrame(
      maxWidth: 760,
      child: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          if (!widget.standalone)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'Settings',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
            ),
          const Text(
            'Connect to your scraper',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'Your server address is hidden. Leave this field blank to keep your current connection, or enter a new address to change it.',
          ),
          const SizedBox(height: 22),
          TextField(
            controller: address,
            enabled: !testing,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'API address',
              hintText: 'Enter a new server address',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: token,
            enabled: !testing,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API token (if configured)',
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: testing ? null : save,
            child: testing
                ? MovieBoxLoader(
                    label: saving ? 'Saving connection' : 'Connecting',
                    compact: true,
                  )
                : const Text('Connect and save'),
          ),
          const SizedBox(height: 10),
          const Text(
            'Use this app and server only on a trusted network or private VPN.',
          ),
          const Divider(height: 32),
          const DonateButton(),
          const SizedBox(height: 10),
          const Text(
            'Donations are optional and do not unlock features. Opens an external support page; review its public donor notice before donating.',
          ),
          const SizedBox(height: 12),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Credits and licenses'),
            subtitle: const Text('Movie Box by R3AP3R Editz'),
            onTap: () => openPage(context, (_) => const CreditsScreen()),
          ),
        ],
      ),
    );
    return widget.standalone
        ? Scaffold(
            appBar: AppBar(title: const Text('Server settings')),
            body: SafeArea(child: content),
          )
        : content;
  }
}

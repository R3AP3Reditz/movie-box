import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

import 'api.dart';
import 'desktop.dart';
import 'library.dart';
import 'screens.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktopWindow) {
    VideoPlayerMediaKit.ensureInitialized(linux: true, windows: true);
  }
  final library = MovieLibrary(await SharedPreferences.getInstance());
  runApp(MovieBoxApp(library: library));
  unawaited(library.backfillThumbnails());
}

class MovieBoxApp extends StatefulWidget {
  final MovieLibrary library;
  const MovieBoxApp({super.key, required this.library});
  @override
  State<MovieBoxApp> createState() => _MovieBoxAppState();
}

class _MovieBoxAppState extends State<MovieBoxApp> with WidgetsBindingObserver {
  late MovieApi api = MovieApi(
    baseUrl: widget.library.server,
    token: widget.library.token,
  );
  int tab = 0;
  final messengerKey = GlobalKey<ScaffoldMessengerState>();

  Future<void> restoreDownloads() async {
    try {
      await widget.library.initializeDownloads();
    } catch (error) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        messengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('Could not restore downloads: $error'),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => unawaited(restoreDownloads()),
            ),
          ),
        );
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(restoreDownloads());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(restoreDownloads());
      unawaited(widget.library.backfillThumbnails());
    }
  }

  void updated() {
    api.close();
    setState(
      () => api = MovieApi(
        baseUrl: widget.library.server,
        token: widget.library.token,
      ),
    );
  }

  void selectTab(int index) {
    if (tab == index) return;
    setState(() => tab = index);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF101519);
    const surface = Color(0xFF1D2529);
    const accent = Color(0xFFF2B86B);
    return MaterialApp(
      scaffoldMessengerKey: messengerKey,
      title: 'MovieBox',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const DesktopScrollBehavior(),
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        pageTransitionsTheme: PageTransitionsTheme(
          builders: {
            ...const PageTransitionsTheme().builders,
            // Desktop video textures cannot be snapshotted during navigation.
            TargetPlatform.linux: const ZoomPageTransitionsBuilder(
              allowSnapshotting: false,
            ),
            TargetPlatform.windows: const ZoomPageTransitionsBuilder(
              allowSnapshotting: false,
            ),
          },
        ),
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: accent,
          surface: surface,
          onSurface: Color(0xFFF0F1ED),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          elevation: 0,
        ),
        cardTheme: const CardThemeData(color: surface),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      home: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= wideLayoutBreakpoint;
          final extended = constraints.maxWidth >= 1200;
          final pages = IndexedStack(
            index: tab,
            children: [
              TickerMode(
                enabled: tab == 0,
                child: HomeScreen(api: api, library: widget.library),
              ),
              TickerMode(
                enabled: tab == 1,
                child: BookmarksScreen(api: api, library: widget.library),
              ),
              TickerMode(
                enabled: tab == 2,
                child: SearchScreen(
                  api: api,
                  library: widget.library,
                  active: tab == 2,
                ),
              ),
              TickerMode(
                enabled: tab == 3,
                child: LibraryScreen(api: api, library: widget.library),
              ),
              TickerMode(
                enabled: tab == 4,
                child: SettingsScreen(
                  api: api,
                  library: widget.library,
                  onSaved: updated,
                ),
              ),
            ],
          );
          return CallbackShortcuts(
            bindings: {
              for (final (index, key) in const [
                LogicalKeyboardKey.digit1,
                LogicalKeyboardKey.digit2,
                LogicalKeyboardKey.digit3,
                LogicalKeyboardKey.digit4,
                LogicalKeyboardKey.digit5,
              ].indexed) ...{
                SingleActivator(key, control: true): () => selectTab(index),
                SingleActivator(key, meta: true): () => selectTab(index),
              },
              const SingleActivator(
                LogicalKeyboardKey.keyF,
                control: true,
              ): () =>
                  selectTab(2),
              const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () =>
                  selectTab(2),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                body: SafeArea(
                  child: wide
                      ? Row(
                          children: [
                            NavigationRail(
                              selectedIndex: tab,
                              onDestinationSelected: selectTab,
                              extended: extended,
                              scrollable: true,
                              leading: extended
                                  ? const Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        14,
                                        18,
                                        14,
                                        22,
                                      ),
                                      child: Text(
                                        'MovieBox',
                                        style: TextStyle(
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFFF2B86B),
                                        ),
                                      ),
                                    )
                                  : const Padding(
                                      padding: EdgeInsets.only(
                                        top: 12,
                                        bottom: 8,
                                      ),
                                      child: Icon(
                                        Icons.movie_filter_outlined,
                                        color: Color(0xFFF2B86B),
                                      ),
                                    ),
                              labelType: extended
                                  ? NavigationRailLabelType.none
                                  : NavigationRailLabelType.all,
                              destinations: const [
                                NavigationRailDestination(
                                  icon: Icon(Icons.home_outlined),
                                  selectedIcon: Icon(Icons.home),
                                  label: Text('Home'),
                                ),
                                NavigationRailDestination(
                                  icon: Icon(Icons.bookmark_border),
                                  selectedIcon: Icon(Icons.bookmark),
                                  label: Text('Library'),
                                ),
                                NavigationRailDestination(
                                  icon: Icon(Icons.search),
                                  label: Text('Search'),
                                ),
                                NavigationRailDestination(
                                  icon: Icon(Icons.download_outlined),
                                  selectedIcon: Icon(Icons.download),
                                  label: Text('Downloads'),
                                ),
                                NavigationRailDestination(
                                  icon: Icon(Icons.settings_outlined),
                                  selectedIcon: Icon(Icons.settings),
                                  label: Text('Settings'),
                                ),
                              ],
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(child: pages),
                          ],
                        )
                      : pages,
                ),
                bottomNavigationBar: wide
                    ? null
                    : NavigationBar(
                        selectedIndex: tab,
                        onDestinationSelected: selectTab,
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home_outlined),
                            selectedIcon: Icon(Icons.home),
                            label: 'Home',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.bookmark_border),
                            selectedIcon: Icon(Icons.bookmark),
                            label: 'Library',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.search),
                            label: 'Search',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.download_outlined),
                            selectedIcon: Icon(Icons.download),
                            label: 'Downloads',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.settings_outlined),
                            selectedIcon: Icon(Icons.settings),
                            label: 'Settings',
                          ),
                        ],
                      ),
              ),
            ),
          );
        },
      ),
      routes: {
        '/settings': (_) => SettingsScreen(
          api: api,
          library: widget.library,
          onSaved: updated,
          standalone: true,
        ),
      },
    );
  }
}

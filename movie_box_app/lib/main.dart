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

/// Fade and a short slide. Desktop video textures cannot be snapshotted,
/// so this builder does not use a zoom snapshot.
class MovieBoxPageTransitions extends PageTransitionsBuilder {
  const MovieBoxPageTransitions();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 340);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final incoming = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    final outgoing = CurvedAnimation(
      parent: secondaryAnimation,
      curve: Curves.easeOutCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-0.08, 0),
      ).animate(outgoing),
      child: FadeTransition(
        opacity: Tween<double>(begin: 1, end: 0.55).animate(outgoing),
        child: FadeTransition(
          opacity: incoming,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.14, 0),
              end: Offset.zero,
            ).animate(incoming),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _TabMotion extends StatelessWidget {
  final AnimationController motion;
  final int from;
  final int to;
  final Widget child;

  const _TabMotion({
    required this.motion,
    required this.from,
    required this.to,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return AnimatedBuilder(
      animation: motion,
      child: child,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(motion.value);
        final direction = to >= from ? 1.0 : -1.0;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset((1 - t) * 84 * direction, (1 - t) * 10),
            child: Transform.scale(
              scale: 0.96 + 0.04 * t,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class MovieBoxApp extends StatefulWidget {
  final MovieLibrary library;
  const MovieBoxApp({super.key, required this.library});
  @override
  State<MovieBoxApp> createState() => _MovieBoxAppState();
}

class _MovieBoxAppState extends State<MovieBoxApp>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late MovieApi api = MovieApi(
    baseUrl: widget.library.server,
    token: widget.library.token,
  );
  int tab = 0;
  int tabFrom = 0;
  late final AnimationController tabMotion;
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
    tabMotion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      value: 1,
    );
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
    tabFrom = tab;
    setState(() => tab = index);
    if (MediaQuery.disableAnimationsOf(context)) {
      tabMotion.value = 1;
    } else {
      tabMotion.forward(from: 0);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    tabMotion.dispose();
    api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF101519);
    const surface = Color(0xFF1D2529);
    const accent = Color(0xFFF2B86B);
    final focusSide = WidgetStateProperty.resolveWith<BorderSide?>((states) {
      if (states.contains(WidgetState.focused)) {
        return const BorderSide(color: Color(0xFFFFE0A8), width: 2.5);
      }
      return BorderSide.none;
    });
    final focusFill = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.focused)) {
        return const Color(0x66F2B86B);
      }
      return null;
    });
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
            TargetPlatform.linux: const MovieBoxPageTransitions(),
            TargetPlatform.windows: const MovieBoxPageTransitions(),
            TargetPlatform.macOS: const MovieBoxPageTransitions(),
          },
        ),
        focusColor: const Color(0xAAF2B86B),
        hoverColor: const Color(0x22F2B86B),
        colorScheme: const ColorScheme.dark(
          primary: accent,
          secondary: accent,
          surface: surface,
          onSurface: Color(0xFFF0F1ED),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom().copyWith(
            side: focusSide,
            overlayColor: focusFill,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom().copyWith(
            side: focusSide,
            overlayColor: focusFill,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom().copyWith(
            side: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.focused)) {
                return const BorderSide(color: Color(0xFFFFE0A8), width: 2.5);
              }
              return const BorderSide(color: Color(0xFF5C676C));
            }),
            overlayColor: focusFill,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom().copyWith(
            side: focusSide,
            overlayColor: focusFill,
          ),
        ),
        listTileTheme: const ListTileThemeData(
          selectedTileColor: Color(0x33F2B86B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
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
          final pages = _TabMotion(
            motion: tabMotion,
            from: tabFrom,
            to: tab,
            child: IndexedStack(
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
            ),
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
                      ? Stack(
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 78),
                              child: pages,
                            ),
                            Positioned(
                              left: 14,
                              top: 0,
                              bottom: 0,
                              child: Center(
                                child: DesktopSidebar(
                                  selected: tab,
                                  extended: extended,
                                  onSelected: selectTab,
                                ),
                              ),
                            ),
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

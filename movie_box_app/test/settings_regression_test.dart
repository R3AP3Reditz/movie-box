import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:movie_box_app/api.dart';
import 'package:movie_box_app/library.dart';
import 'package:movie_box_app/main.dart';
import 'package:movie_box_app/notices.dart';
import 'package:movie_box_app/screens.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'downloads_test.dart' show FakeDownloadBackend;

class _Launcher extends UrlLauncherPlatform {
  final calls = <String>[];
  LaunchOptions? options;
  Future<bool> Function() result = () async => true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) {
    calls.add(url);
    this.options = options;
    return result();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MovieLibrary library;
  late MovieApi api;
  late MockClient client;
  late List<http.Request> requests;
  late _Launcher launcher;
  final listScrollable = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    library = MovieLibrary(
      await SharedPreferences.getInstance(),
      downloadBackend: FakeDownloadBackend(),
    );
    requests = [];
    client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({'ok': true, 'banners': [], 'sections': []}),
        200,
      );
    });
    api = MovieApi(baseUrl: library.server, client: client);
    final original = UrlLauncherPlatform.instance;
    launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = original);
    addTearDown(api.close);
    addTearDown(library.dispose);
  });

  Future<void> mount(WidgetTester tester, {bool standalone = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: standalone
            ? SettingsScreen(
                api: api,
                library: library,
                onSaved: () {},
                standalone: true,
              )
            : Scaffold(
                body: SettingsScreen(
                  api: api,
                  library: library,
                  onSaved: () {},
                ),
              ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectHidden(WidgetTester tester) {
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      isEmpty,
    );
    expect(find.textContaining(library.server), findsNothing);
    expect(find.textContaining('movie-box.n92dev.us.kg'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byType(TextField).first)
          .decoration!
          .hintText,
      'Enter a new server address',
    );
  }

  for (final standalone in [false, true]) {
    for (final custom in [false, true]) {
      testWidgets(
        'Settings hides ${custom ? 'saved' : 'default'} address, standalone=$standalone',
        (tester) async {
          if (custom) {
            await library.configure('https://private.example', 'token');
          }
          await mount(tester, standalone: standalone);
          expectHidden(tester);
          expect(requests, isEmpty);
        },
      );
    }
  }

  testWidgets('blank address keeps current server while updating token', (
    tester,
  ) async {
    await library.configure('https://private.example', 'old-token');
    await http.runWithClient(() async {
      await mount(tester);
      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.enterText(find.byType(TextField).last, 'new-token');
      await tester.tap(find.text('Connect and save'));
      await tester.pumpAndSettle();
      expect(requests.single.url.toString(), 'https://private.example/health');
      expect(requests.single.headers['Authorization'], 'Bearer new-token');
      expect(library.server, 'https://private.example');
      expect(library.token, 'new-token');
      expectHidden(tester);
    }, () => client);
  });

  testWidgets('blank address uses default server without revealing it', (
    tester,
  ) async {
    expect(library.server, 'https://movie.mizuki.to');
    final defaultServer = library.server;
    await http.runWithClient(() async {
      await mount(tester);
      await tester.tap(find.text('Connect and save'));
      await tester.pumpAndSettle();
      expect(requests.single.url.toString(), '$defaultServer/health');
      expect(library.server, defaultServer);
      expectHidden(tester);
    }, () => client);
  });

  testWidgets('saved replacement is hidden and used after navigating tabs', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await tester.pumpWidget(MovieBoxApp(library: library));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Settings'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'https://replacement.example',
      );
      await tester.tap(find.text('Connect and save'));
      await tester.pumpAndSettle();
      expect(library.server, 'https://replacement.example');
      expectHidden(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Home'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        requests.any(
          (r) => r.url.toString() == 'https://replacement.example/v1/home',
        ),
        isTrue,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text('Settings'),
        ),
      );
      await tester.pumpAndSettle();
      expectHidden(tester);
      expect(tester.takeException(), isNull);
    }, () => client);
  });

  for (final size in [const Size(390, 844), const Size(1280, 720)]) {
    testWidgets('Settings Donate opens external browser at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      await tester.scrollUntilVisible(
        find.text('Donate'),
        150,
        scrollable: listScrollable,
      );
      await tester.tap(find.text('Donate'));
      await tester.pumpAndSettle();
      expect(launcher.calls, [donationUrl]);
      expect(launcher.options!.mode, PreferredLaunchMode.externalApplication);
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Credits Donate shares the same donation link', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CreditsScreen()));
    await tester.scrollUntilVisible(
      find.text('Donate'),
      150,
      scrollable: listScrollable,
    );
    await tester.tap(find.text('Donate'));
    await tester.pumpAndSettle();
    expect(launcher.calls, [donationUrl]);
    expect(tester.takeException(), isNull);
  });

  for (final throws in [false, true]) {
    testWidgets(
      'Donate browser failure offers working copy fallback, throws=$throws',
      (tester) async {
        launcher.result = () async {
          if (throws) throw PlatformException(code: 'NO_BROWSER');
          return false;
        };
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await mount(tester);
        await tester.scrollUntilVisible(
          find.text('Donate'),
          150,
          scrollable: listScrollable,
        );
        await tester.tap(find.text('Donate'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Could not open a browser'), findsOneWidget);
        await tester.tap(find.text('Copy link'));
        await tester.pumpAndSettle();
        expect(copied, donationUrl);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Credits and standalone Settings respect system navigation padding',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      tester.view.padding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPadding);
      await tester.pumpWidget(const MaterialApp(home: CreditsScreen()));
      await tester.scrollUntilVisible(
        find.text('Copy donation link'),
        150,
        scrollable: listScrollable,
      );
      expect(
        tester.getBottomRight(find.byType(ListView)).dy,
        lessThanOrEqualTo(810),
      );
      await mount(tester, standalone: true);
      expect(
        tester.getBottomRight(find.byType(ListView)).dy,
        lessThanOrEqualTo(810),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Donate prevents duplicate launches and handles disposal', (
    tester,
  ) async {
    final opened = Completer<bool>();
    launcher.result = () => opened.future;
    await mount(tester);
    await tester.scrollUntilVisible(
      find.text('Donate'),
      150,
      scrollable: listScrollable,
    );
    await tester.tap(find.text('Donate'));
    await tester.pump();
    await tester.tap(find.text('Opening donation page'));
    expect(launcher.calls, [donationUrl]);
    await tester.pumpWidget(const SizedBox.shrink());
    opened.complete(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

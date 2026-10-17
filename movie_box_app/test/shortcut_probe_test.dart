import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_box_app/library.dart';
import 'package:movie_box_app/main.dart';

import 'downloads_test.dart' show FakeDownloadBackend;

void main() {
  testWidgets('probe: desktop shortcuts switch tabs', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final library = MovieLibrary(
      await SharedPreferences.getInstance(),
      downloadBackend: FakeDownloadBackend(),
    );
    await tester.binding.setSurfaceSize(const Size(1280, 720));
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MovieBoxApp(library: library));

    int? selected() =>
        tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex;

    expect(selected(), 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    // ignore: avoid_print
    print('after ctrl+4 -> ${selected()}');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    // ignore: avoid_print
    print('after ctrl+f -> ${selected()}');
  });
}
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:movie_box_app/desktop.dart';
import 'package:movie_box_app/library.dart';
import 'package:movie_box_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'downloads_test.dart' show FakeDownloadBackend;

void main() {
  testWidgets('desktop shortcuts switch tabs on a wide window', (tester) async {
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

    DesktopSidebar rail() =>
        tester.widget<DesktopSidebar>(find.byType(DesktopSidebar));

    Future<void> chord(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    expect(rail().selected, 0, reason: 'Home is selected on launch');

    await chord(LogicalKeyboardKey.digit4);
    expect(rail().selected, 3, reason: 'Ctrl+4 selects Downloads');

    await chord(LogicalKeyboardKey.keyF);
    expect(rail().selected, 2, reason: 'Ctrl+F selects Search');

    await chord(LogicalKeyboardKey.digit1);
    expect(rail().selected, 0, reason: 'Ctrl+1 returns to Home');
  });
}

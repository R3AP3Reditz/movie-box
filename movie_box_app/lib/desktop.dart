import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// True when the app runs as a resizable desktop window rather than a phone.
///
/// Linux and Windows share one desktop layout: a navigation rail, bounded
/// content, mouse-draggable carousels, and a native fullscreen method channel
/// implemented by both platform runners.
bool get isDesktopWindow =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Width at which the shell switches from a bottom bar to a navigation rail.
const double wideLayoutBreakpoint = 900;

/// Width at which detail and settings content splits into columns.
const double splitLayoutBreakpoint = 1000;

/// Desktop pointer support: mouse drag on carousels and visible scrollbars.
class DesktopScrollBehavior extends MaterialScrollBehavior {
  const DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
  };
}

/// Sizes poster tiles for the window width so they stay a comfortable size
/// instead of stretching across a large monitor.
double posterWidth(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= 1700) return 178;
  if (width >= 1300) return 162;
  if (width >= wideLayoutBreakpoint) return 148;
  return 130;
}

/// How many columns keep a grid tile near its intended size. Tiles stay a
/// constant width instead of stretching when the window grows.
int gridColumns(BuildContext context, {double tileTarget = 155}) {
  final width = MediaQuery.sizeOf(context).width;
  final columns = (width / tileTarget).floor();
  return columns.clamp(2, 16);
}

/// Centers content and caps its width so text and forms stay readable on wide
/// displays.
class ContentFrame extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  final Alignment alignment;
  final EdgeInsetsGeometry padding;

  const ContentFrame({
    super.key,
    required this.child,
    this.maxWidth = 1100,
    this.alignment = Alignment.topCenter,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) => Align(
    alignment: alignment,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: SizedBox(
        width: double.infinity,
        child: Padding(padding: padding, child: child),
      ),
    ),
  );
}

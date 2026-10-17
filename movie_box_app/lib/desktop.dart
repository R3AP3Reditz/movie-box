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

/// How many columns keep a grid tile near its intended size. Pass the width
/// of the grid itself. The window includes the sidebar, so using the full
/// window packs too many columns into the remaining space.
int gridColumns(
  BuildContext context, {
  double? width,
  double tileTarget = 168,
}) {
  final available = width ?? MediaQuery.sizeOf(context).width;
  final columns = (available / tileTarget).floor();
  return columns.clamp(2, 12);
}

/// Left rail for a desktop window. Phone layouts keep the bottom bar.
class DesktopSidebar extends StatelessWidget {
  final int selected;
  final bool extended;
  final ValueChanged<int> onSelected;

  const DesktopSidebar({
    super.key,
    required this.selected,
    required this.extended,
    required this.onSelected,
  });

  static const _items = [
    (Icons.home_outlined, Icons.home, 'Home'),
    (Icons.bookmark_border, Icons.bookmark, 'Library'),
    (Icons.search, Icons.search, 'Search'),
    (Icons.download_outlined, Icons.download, 'Downloads'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF01A2226),
      elevation: 8,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(28),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, item) in _items.indexed)
              _Destination(
                icon: selected == index ? item.$2 : item.$1,
                label: item.$3,
                selected: selected == index,
                onTap: () => onSelected(index),
              ),
          ],
        ),
      ),
    );
  }
}

class _Destination extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Destination({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Tooltip(
        message: label,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOut,
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFF2B86B) : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Icon(
              icon,
              size: 22,
              color: selected
                  ? const Color(0xFF1A140C)
                  : const Color(0xFFE4E8E6),
            ),
          ),
        ),
      ),
    );
  }
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

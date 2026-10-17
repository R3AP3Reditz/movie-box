import 'package:flutter/material.dart';

/// Remembers pages that were closed with Back so mouse Forward can open them.
class NavMemory extends NavigatorObserver {
  final List<void Function(NavigatorState)> forward = [];
  bool restoring = false;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (!restoring) forward.clear();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final settings = route.settings;
    if (settings is ReplayRouteSettings) {
      forward.add((navigator) => navigator.push(settings.replay()));
    } else if (settings.name != null &&
        settings.name != Navigator.defaultRouteName) {
      final name = settings.name!;
      forward.add((navigator) => navigator.pushNamed(name));
    }
  }

  void goForward(NavigatorState navigator) {
    if (forward.isEmpty) return;
    final replay = forward.removeLast();
    restoring = true;
    replay(navigator);
    restoring = false;
  }
}

class ReplayRouteSettings extends RouteSettings {
  final Route<dynamic> Function() replay;
  const ReplayRouteSettings(this.replay);
}

Future<T?> openPage<T>(BuildContext context, WidgetBuilder builder) {
  late Route<T> Function() replay;
  replay = () => MaterialPageRoute<T>(
    settings: ReplayRouteSettings(replay),
    builder: builder,
  );
  return Navigator.of(context).push(replay());
}

import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'remote_focus.dart';

/// Keep native NavigationBar buttons and preserve focus across dock rebuilds.
class RemoteDockFocus {
  final _container = FocusNode(skipTraversal: true);
  bool get hasFocus => _container.hasFocus;

  Widget wrap(Widget child) => !androidRemoteEnabled
      ? child
      : RemoteNavigationRegion(
          child: Focus(focusNode: _container, child: child),
        );

  void requestCurrent(int index) {
    if (!androidRemoteEnabled) return;
    final nodes = _container.traversalDescendants.toList();
    if (nodes.isNotEmpty) {
      nodes[index.clamp(0, nodes.length - 1)].requestFocus();
    } else {
      _container.requestFocus();
    }
  }

  void preserveOnSwitch(int index) {
    if (!_container.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_container.context?.mounted ?? false) requestCurrent(index);
    });
  }

  void dispose() => _container.dispose();
}

/// Player shortcuts must yield while the app navigation holds focus.
class RemoteNavigationRegion extends StatelessWidget {
  const RemoteNavigationRegion({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

/// Hardware Back already provides this action for remote users.
class RemoteBackButton extends IconButton {
  const RemoteBackButton({
    super.key,
    required super.icon,
    super.tooltip,
    super.onPressed,
    super.iconSize,
    super.constraints,
    super.padding,
    super.style,
    super.color,
  });

  @override
  Widget build(BuildContext context) => ExcludeFocus(
    excluding: androidRemoteEnabled,
    child: super.build(context),
  );
}

class RemoteBackControl extends StatelessWidget {
  const RemoteBackControl({super.key});
  @override
  Widget build(BuildContext context) =>
      ExcludeFocus(excluding: androidRemoteEnabled, child: const BackButton());
}

Widget? remotePageBackButton(BuildContext context) =>
    androidRemoteEnabled && Navigator.canPop(context)
    ? const RemoteBackControl()
    : null;

AppBar remotePageAppBar(
  BuildContext context, {
  required Widget title,
  bool? centerTitle,
  Color? backgroundColor,
  Color? surfaceTintColor,
  List<Widget>? actions,
}) => AppBar(
  leading: remotePageBackButton(context),
  title: title,
  centerTitle: centerTitle,
  backgroundColor: backgroundColor,
  surfaceTintColor: surfaceTintColor,
  actions: actions,
);

const remoteRootDestinations = <Widget>[
  NavigationDestination(
    icon: Icon(LucideIcons.house),
    selectedIcon: Icon(LucideIcons.house),
    label: '首页',
  ),
  NavigationDestination(
    icon: Icon(LucideIcons.clapperboard),
    selectedIcon: Icon(LucideIcons.clapperboard),
    label: '短剧',
  ),
  NavigationDestination(
    icon: Icon(LucideIcons.library_big),
    selectedIcon: Icon(LucideIcons.library_big),
    label: '书架',
  ),
  NavigationDestination(
    icon: Icon(LucideIcons.circle_user_round),
    selectedIcon: Icon(LucideIcons.circle_user_round),
    label: '我的',
  ),
];

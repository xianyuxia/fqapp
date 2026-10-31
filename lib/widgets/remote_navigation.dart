import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import 'remote_focus.dart';

/// Keep native NavigationBar buttons and focus the selected one on Menu.
class RemoteDockFocus {
  final _container = FocusNode(canRequestFocus: false, skipTraversal: true);

  Widget wrap(Widget child) => !androidRemoteEnabled
      ? child
      : RemoteNavigationRegion(
          child: Focus(
            focusNode: _container,
            onKeyEvent: _direction,
            child: child,
          ),
        );

  KeyEventResult _direction(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final nodes = _container.traversalDescendants.toList();
      final current = nodes.indexWhere((node) => node.hasPrimaryFocus);
      if (current >= 0) {
        final step = key == LogicalKeyboardKey.arrowLeft ? -1 : 1;
        nodes[(current + step).clamp(0, nodes.length - 1)].requestFocus();
      }
    }
    return KeyEventResult.handled;
  }

  void requestCurrent(int index) {
    if (!androidRemoteEnabled) return;
    final nodes = _container.traversalDescendants.toList();
    if (nodes.isNotEmpty) {
      nodes[index.clamp(0, nodes.length - 1)].requestFocus();
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

/// Handle Menu even before a content control has received the first focus.
class RemoteDockMenu extends StatefulWidget {
  const RemoteDockMenu({
    super.key,
    required this.dock,
    required this.index,
    required this.enabled,
    required this.child,
  });
  final RemoteDockFocus dock;
  final int index;
  final bool enabled;
  final Widget child;
  @override
  State<RemoteDockMenu> createState() => _RemoteDockMenuState();
}

class _RemoteDockMenuState extends State<RemoteDockMenu> {
  bool _held = false;
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_key);
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_key);
    super.dispose();
  }

  KeyEventResult _key(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.contextMenu ||
        !androidRemoteEnabled) {
      return KeyEventResult.ignored;
    }
    if (_held && event is KeyUpEvent) {
      _held = false;
      return KeyEventResult.handled;
    }
    if (_held && event is KeyRepeatEvent) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    if (!widget.enabled ||
        ModalRoute.of(context)?.isCurrent != true ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    _held = true;
    widget.dock.requestCurrent(widget.index);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => widget.child;
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

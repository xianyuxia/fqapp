import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'remote_focus.dart';
import 'remote_navigation.dart';
import 'remote_root_navigation.dart';

/// Marks an existing feed action; no extra button or menu is introduced.
class RemoteFeedAction extends StatelessWidget {
  const RemoteFeedAction({super.key, required this.index, required this.child});
  final int index;
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

/// A recommendation feed browses dramas vertically and its action row sideways.
class RemoteFeedNavigation extends StatefulWidget {
  const RemoteFeedNavigation({
    super.key,
    required this.enabled,
    required this.onStep,
    required this.onOpen,
    required this.child,
  });
  final bool enabled;
  final Future<void> Function(int delta) onStep;
  final VoidCallback onOpen;
  final Widget child;

  @override
  State<RemoteFeedNavigation> createState() => _RemoteFeedNavigationState();
}

class _RemoteFeedNavigationState extends State<RemoteFeedNavigation> {
  final _entry = FocusNode(debugLabel: 'drama recommendation feed');
  final _held = <LogicalKeyboardKey>{};
  bool _switching = false;

  List<FocusNode> get _actions {
    final nodes = _entry.traversalDescendants
        .where((node) => node.canRequestFocus && _action(node) != null)
        .toList();
    nodes.sort((a, b) => _action(a)!.index.compareTo(_action(b)!.index));
    return nodes;
  }

  RemoteFeedAction? _action(FocusNode node) =>
      node.context?.findAncestorWidgetOfExactType<RemoteFeedAction>();

  void _enter() {
    final actions = _actions;
    (actions.isEmpty ? _entry : actions.first).requestFocus();
  }

  @override
  void didUpdateWidget(RemoteFeedNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled && _entry.hasPrimaryFocus) _enter();
    });
  }

  Future<void> _step(int delta) async {
    if (_switching) return;
    _switching = true;
    try {
      await widget.onStep(delta);
      if (!mounted) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted ||
          !widget.enabled ||
          !TickerMode.valuesOf(context).enabled ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      final focus = FocusManager.instance.primaryFocus?.context;
      if (focus?.findAncestorWidgetOfExactType<RemoteNavigationRegion>() ==
          null) {
        _enter();
      }
    } finally {
      _switching = false;
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent && _held.remove(key)) return KeyEventResult.handled;
    if (event is KeyRepeatEvent && _held.contains(key)) {
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    if (!widget.enabled ||
        ModalRoute.of(context)?.isCurrent != true ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final vertical =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown;
    final horizontal =
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    final confirm =
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
    if (!vertical &&
        !horizontal &&
        !confirm &&
        key != LogicalKeyboardKey.contextMenu) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    _held.add(key);
    if (vertical) {
      unawaited(_step(key == LogicalKeyboardKey.arrowUp ? -1 : 1));
    } else if (horizontal) {
      final actions = _actions;
      if (actions.isNotEmpty) {
        final focused = actions.indexWhere((node) => node.hasPrimaryFocus);
        final index = focused < 0 ? 0 : focused;
        final delta = key == LogicalKeyboardKey.arrowLeft ? -1 : 1;
        actions[(index + delta).clamp(0, actions.length - 1)].requestFocus();
      }
    } else if (confirm && _entry.hasPrimaryFocus) {
      widget.onOpen();
    }
    // Menu intentionally has no episode action in a browsing feed.
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RemoteContentEntry(
    focusNode: _entry,
    enabled: androidRemoteEnabled && widget.enabled,
    onEnter: _enter,
    onKeyEvent: _key,
    child: widget.child,
  );
}

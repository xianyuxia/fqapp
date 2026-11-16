import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../services/remote_input_devices.dart';
import 'remote_focus.dart';
import 'remote_navigation.dart';

/// Root destinations switch on Left/Right; Up enters content and Back returns.
class RemoteRootNavigation extends StatefulWidget {
  const RemoteRootNavigation({
    super.key,
    required this.dock,
    required this.index,
    required this.onSelect,
    this.onRevealDock,
    required this.child,
  });
  final RemoteDockFocus dock;
  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback? onRevealDock;
  final Widget child;

  @override
  State<RemoteRootNavigation> createState() => _RemoteRootNavigationState();
}

class _RemoteRootNavigationState extends State<RemoteRootNavigation> {
  final _devices = RemoteInputDevices();
  final _content = FocusScopeNode(debugLabel: 'root page content');
  final _entries = <_RemoteContentEntryState>{};
  final _held = <LogicalKeyboardKey>{};
  bool _remoteActive = false;
  bool _connected = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    if (!androidRemoteEnabled) return;
    FocusManager.instance.addEarlyKeyEventHandler(_key);
    FocusManager.instance.addListener(_focusChanged);
    unawaited(_devices.watch(_connectionChanged));
  }

  void _connectionChanged(bool connected) {
    if (!mounted) return;
    final attached = connected && !_connected;
    _connected = connected;
    if (!attached) return;
    activateRemoteFocus();
    setState(() => _remoteActive = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_started && ModalRoute.of(context)?.isCurrent == true) {
        _returnToDock();
      }
    });
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  void _returnToDock() {
    _started = true;
    widget.onRevealDock?.call();
    widget.dock.requestCurrent(widget.index);
    if (widget.onRevealDock != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.dock.hasFocus) {
          widget.dock.requestCurrent(widget.index);
        }
      });
    }
  }

  void _enterContent() {
    for (final entry in _entries) {
      if (entry.widget.enabled && TickerMode.valuesOf(entry.context).enabled) {
        entry.enter();
        return;
      }
    }
    _content.requestFocus();
    if (_content.focusedChild == null) _content.nextFocus();
  }

  static final _arrows = {
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
  };
  static final _back = {LogicalKeyboardKey.escape, LogicalKeyboardKey.goBack};

  KeyEventResult _key(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent && _held.remove(key)) return KeyEventResult.handled;
    if (event is KeyRepeatEvent && _held.contains(key)) {
      return KeyEventResult.handled;
    }
    if (!_canHandle(event)) return KeyEventResult.ignored;
    if (_back.contains(key) && !widget.dock.hasFocus && _remoteActive) {
      _held.add(key);
      _returnToDock();
      return KeyEventResult.handled;
    }
    if (!_arrows.contains(key)) return KeyEventResult.ignored;
    if (!_started) {
      setState(() => _remoteActive = true);
      _returnToDock();
    } else if (!widget.dock.hasFocus) {
      return KeyEventResult.ignored;
    }
    activateRemoteFocus();
    _held.add(key);
    if (key == LogicalKeyboardKey.arrowUp) {
      _enterContent();
    } else if (key != LogicalKeyboardKey.arrowDown) {
      final delta = key == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      final next = (widget.index + delta).clamp(
        0,
        remoteRootDestinations.length - 1,
      );
      if (next != widget.index) widget.onSelect(next);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.dock.requestCurrent(next);
      });
    }
    return KeyEventResult.handled;
  }

  bool _canHandle(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (event is! KeyDownEvent ||
        ModalRoute.of(context)?.isCurrent != true ||
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden ||
        keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    return focus?.widget is! EditableText &&
        focus?.findAncestorWidgetOfExactType<EditableText>() == null;
  }

  @override
  void dispose() {
    _devices.dispose();
    FocusManager.instance.removeEarlyKeyEventHandler(_key);
    FocusManager.instance.removeListener(_focusChanged);
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!androidRemoteEnabled) return widget.child;
    return _RemoteRootScope(
      state: this,
      child: PopScope(
        canPop: !_remoteActive || widget.dock.hasFocus,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && ModalRoute.of(context)?.isCurrent == true) {
            _returnToDock();
          }
        },
        child: widget.child,
      ),
    );
  }
}

class _RemoteRootScope extends InheritedWidget {
  const _RemoteRootScope({required this.state, required super.child});
  final _RemoteRootNavigationState state;
  @override
  bool updateShouldNotify(_RemoteRootScope oldWidget) =>
      state != oldWidget.state;
}

/// Separates page traversal from the floating bottom navigation.
class RemoteContentArea extends StatelessWidget {
  const RemoteContentArea({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final root = context.dependOnInheritedWidgetOfExactType<_RemoteRootScope>();
    return root == null
        ? child
        : FocusScope(node: root.state._content, child: child);
  }
}

/// A page can supply a deterministic entry instead of geometric focus guessing.
class RemoteContentEntry extends StatefulWidget {
  const RemoteContentEntry({
    super.key,
    required this.focusNode,
    required this.enabled,
    required this.onEnter,
    required this.onKeyEvent,
    required this.child,
  });
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onEnter;
  final FocusOnKeyEventCallback onKeyEvent;
  final Widget child;

  @override
  State<RemoteContentEntry> createState() => _RemoteContentEntryState();
}

class _RemoteContentEntryState extends State<RemoteContentEntry> {
  _RemoteRootNavigationState? _root;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final root = context
        .dependOnInheritedWidgetOfExactType<_RemoteRootScope>()
        ?.state;
    if (root == _root) return;
    _root?._entries.remove(this);
    _root = root;
    _root?._entries.add(this);
  }

  void enter() => widget.onEnter();

  @override
  void dispose() {
    _root?._entries.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: widget.focusNode,
    canRequestFocus: widget.enabled,
    onKeyEvent: widget.enabled ? widget.onKeyEvent : null,
    child: widget.child,
  );
}

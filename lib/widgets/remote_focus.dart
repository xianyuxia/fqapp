import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

bool get androidRemoteEnabled =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Adds keyboard focus to touch-only actions without changing their geometry.
class RemoteGestureDetector extends GestureDetector {
  RemoteGestureDetector({
    super.key,
    super.child,
    this.onMenu,
    this.framePadding = EdgeInsets.zero,
    this.ensureVisible = true,
    super.behavior,
    super.dragStartBehavior,
    super.excludeFromSemantics,
    super.onHorizontalDragCancel,
    super.onHorizontalDragEnd,
    super.onHorizontalDragStart,
    super.onHorizontalDragUpdate,
    super.onLongPress,
    super.onLongPressCancel,
    super.onLongPressEnd,
    super.onLongPressStart,
    super.onTap,
    super.onTapCancel,
    super.onTapDown,
    super.onTapUp,
    super.onVerticalDragCancel,
    super.onVerticalDragEnd,
    super.onVerticalDragStart,
    super.onVerticalDragUpdate,
  });
  final VoidCallback? onMenu;
  final EdgeInsets framePadding;
  final bool ensureVisible;

  @override
  Widget build(BuildContext context) {
    final gesture = super.build(context);
    if (!androidRemoteEnabled || onTap == null) return gesture;
    return RemoteFocus(
      onActivate: onTap!,
      onMenu: onMenu,
      framePadding: framePadding,
      ensureVisible: ensureVisible,
      child: gesture,
    );
  }
}

class RemoteFocus extends StatefulWidget {
  const RemoteFocus({
    super.key,
    required this.onActivate,
    required this.child,
    this.onMenu,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = true,
    this.framePadding = EdgeInsets.zero,
    this.ensureVisible = true,
  });
  final VoidCallback onActivate;
  final VoidCallback? onMenu;
  final Widget child;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool canRequestFocus;
  final EdgeInsets framePadding;
  final bool ensureVisible;

  @override
  State<RemoteFocus> createState() => _RemoteFocusState();
}

class _RemoteFocusState extends State<RemoteFocus> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _remoteInput.attach();
    _remoteInput.addListener(_modeChanged);
  }

  void _modeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _remoteInput.removeListener(_modeChanged);
    _remoteInput.detach();
    super.dispose();
  }

  static final _confirm = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
  };

  @override
  Widget build(BuildContext context) {
    if (!androidRemoteEnabled) return widget.child;
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      canRequestFocus: widget.canRequestFocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _focused && widget.ensureVisible) {
              unawaited(
                Scrollable.ensureVisible(
                  context,
                  duration: const Duration(milliseconds: 120),
                  alignment: .5,
                ),
              );
            }
          });
        }
      },
      onKeyEvent: (node, event) {
        if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (_confirm.contains(key)) {
          if (event is KeyDownEvent) widget.onActivate();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.contextMenu && widget.onMenu != null) {
          if (event is KeyDownEvent) widget.onMenu!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        fit: StackFit.passthrough,
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (_focused && _remoteInput.value)
            Positioned(
              left: -widget.framePadding.left,
              right: -widget.framePadding.right,
              top: -widget.framePadding.top,
              bottom: -widget.framePadding.bottom,
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('remote-focus-ring'),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFFFFB300),
                      width: 3,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Strong focus contrast on light cards and dark player panels alike.
class RemoteInkWell extends InkWell {
  RemoteInkWell({
    super.key,
    super.child,
    super.onTap,
    super.onLongPress,
    super.onTapDown,
    super.onTapUp,
    super.onTapCancel,
    super.borderRadius,
    super.customBorder,
    super.splashColor,
    super.highlightColor,
    super.overlayColor,
    super.onHover,
    super.onFocusChange,
    super.focusNode,
    super.autofocus,
    super.canRequestFocus,
    super.enableFeedback,
    super.excludeFromSemantics,
    super.hoverColor,
    super.mouseCursor,
  }) : super(focusColor: androidRemoteEnabled ? const Color(0x66FFB300) : null);

  @override
  Widget build(BuildContext context) {
    final ink = super.build(context);
    if (!androidRemoteEnabled) return ink;
    return RemoteFocus(
      canRequestFocus: false,
      onActivate: onTap ?? () {},
      child: ink,
    );
  }
}

/// Menu commands bubble from any focused control in the current video feed.
class RemoteMenu extends StatelessWidget {
  const RemoteMenu({super.key, required this.child, this.onMenu});
  final Widget child;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) => !androidRemoteEnabled
      ? child
      : Focus(
          canRequestFocus: false,
          onKeyEvent: (_, event) {
            if (onMenu == null ||
                event.logicalKey != LogicalKeyboardKey.contextMenu) {
              return KeyEventResult.ignored;
            }
            if (event is KeyDownEvent) onMenu!();
            return KeyEventResult.handled;
          },
          child: child,
        );
}

// Android virtual-keyboard sources include some remote bridges. Recognize
// navigation keys directly instead of relying on Flutter's device heuristic.
final _remoteInput = _RemoteInputMode();

/// Show the initial focus when Android reports a connected remote.
void activateRemoteFocus() {
  if (androidRemoteEnabled) _remoteInput.value = true;
}

class _RemoteInputMode extends ValueNotifier<bool> {
  _RemoteInputMode() : super(false);
  int _users = 0;
  static final _navigationKeys = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.contextMenu,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.space,
  };

  void attach() {
    if (_users++ != 0) return;
    FocusManager.instance.addEarlyKeyEventHandler(_key);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointer);
  }

  void detach() {
    if (--_users != 0) return;
    FocusManager.instance.removeEarlyKeyEventHandler(_key);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointer);
  }

  KeyEventResult _key(KeyEvent event) {
    if (!androidRemoteEnabled || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final context = FocusManager.instance.primaryFocus?.context;
    final editing =
        context?.widget is EditableText ||
        context?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (editing && event.logicalKey != LogicalKeyboardKey.tab) {
      return KeyEventResult.ignored;
    }
    if (_navigationKeys.contains(event.logicalKey)) value = true;
    return KeyEventResult.ignored;
  }

  void _pointer(PointerEvent event) {
    if (event is PointerDownEvent) value = false;
  }
}

/// Draw above opaque cards and native buttons, including the bottom navigation.
/// This changes paint only; existing focus traversal and activation stay intact.
class RemoteFocusOverlay extends StatefulWidget {
  const RemoteFocusOverlay({super.key, required this.child});
  final Widget child;
  @override
  State<RemoteFocusOverlay> createState() => _RemoteFocusOverlayState();
}

class _RemotePaintSignal extends ChangeNotifier {
  void update() => notifyListeners();
}

class _RemoteFocusOverlayState extends State<RemoteFocusOverlay> {
  final _root = GlobalKey();
  final _scrollPaint = _RemotePaintSignal();
  late final _paint = Listenable.merge([
    FocusManager.instance,
    _remoteInput,
    _scrollPaint,
  ]);
  @override
  void initState() {
    super.initState();
    _remoteInput.attach();
  }

  @override
  void dispose() {
    _remoteInput.detach();
    _scrollPaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => !androidRemoteEnabled
      ? widget.child
      : NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _scrollPaint.update();
            return false;
          },
          child: Stack(
            key: _root,
            fit: StackFit.expand,
            children: [
              widget.child,
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    key: const ValueKey('remote-active-focus'),
                    painter: _RemoteFocusPainter(_root, _paint),
                  ),
                ),
              ),
            ],
          ),
        );
}

class _RemoteFocusPainter extends CustomPainter {
  _RemoteFocusPainter(this.root, Listenable repaint) : super(repaint: repaint);
  final GlobalKey root;

  @override
  void paint(Canvas canvas, Size size) {
    if (!_remoteInput.value) return;
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node is FocusScopeNode) return;
    // Custom controls already paint a frame that follows their layout animation.
    if (node.context?.findAncestorWidgetOfExactType<RemoteFocus>() != null) {
      return;
    }
    final target = node.context?.findRenderObject();
    final host = root.currentContext?.findRenderObject();
    if (target is! RenderBox ||
        host is! RenderBox ||
        !target.attached ||
        !target.hasSize ||
        !host.hasSize) {
      return;
    }
    final origin = host.globalToLocal(target.localToGlobal(Offset.zero));
    final rect = (origin & target.size).intersect(Offset.zero & size);
    if (rect.isEmpty) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(1.5), const Radius.circular(8)),
      Paint()
        ..color = const Color(0xFFFFB300)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
  }

  @override
  bool shouldRepaint(_RemoteFocusPainter oldDelegate) =>
      root != oldDelegate.root;
}

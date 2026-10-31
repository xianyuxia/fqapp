part of 'video_player_chrome.dart';

enum _PlaybackKeyAction {
  toggle,
  controls,
  catalog,
  backward,
  forward,
  previous,
  next,
}

class _PlaybackKeyboardState {
  bool selecting = false;
  bool navigating = false;
  final controls = FocusScopeNode(debugLabel: 'player page controls');
  final play = FocusNode(debugLabel: 'player play button');

  void dispose() {
    play.dispose();
    controls.dispose();
  }

  final heldKeys = <LogicalKeyboardKey>{};
}

extension _VideoPlayerKeyboard on _VideoPlayerChromeState {
  bool get _ready => widget.enabled && (widget.player?.isCreated ?? false);

  static final _keyActions = {
    LogicalKeyboardKey.contextMenu: _PlaybackKeyAction.catalog,
    LogicalKeyboardKey.space: _PlaybackKeyAction.toggle,
    LogicalKeyboardKey.select: _PlaybackKeyAction.controls,
    LogicalKeyboardKey.enter: _PlaybackKeyAction.controls,
    LogicalKeyboardKey.numpadEnter: _PlaybackKeyAction.controls,
    LogicalKeyboardKey.arrowLeft: _PlaybackKeyAction.backward,
    LogicalKeyboardKey.arrowRight: _PlaybackKeyAction.forward,
    LogicalKeyboardKey.arrowUp: _PlaybackKeyAction.previous,
    LogicalKeyboardKey.arrowDown: _PlaybackKeyAction.next,
  };

  KeyEventResult _handlePlaybackKey(KeyEvent event) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    // Finish a consumed press even if its action opened a route or changed
    // player readiness. Key-up must not activate a newly focused button.
    if (event is KeyUpEvent && _playbackKeyboard.heldKeys.remove(key)) {
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent && _playbackKeyboard.heldKeys.contains(key)) {
      return KeyEventResult.handled;
    }
    final action = _keyActions[key];
    if (action != null &&
        (!_ready || !_appActive) &&
        _playbackKeyboard.controls.hasFocus) {
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    if (action == null ||
        keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        !_ready ||
        !_appActive ||
        _routeCovered ||
        ModalRoute.of(context)?.isCurrent == false ||
        _locked ||
        _panelOpen ||
        _overlayOpen ||
        _seeking ||
        _paging) {
      return KeyEventResult.ignored;
    }
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus?.findAncestorWidgetOfExactType<RemoteNavigationRegion>() !=
            null ||
        focus?.widget is EditableText ||
        focus?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    // Once paused, directions and confirmation belong to the page's existing
    // controls. Keep space as a playback shortcut and menu as direct episodes.
    if (_playbackKeyboard.navigating &&
        action != _PlaybackKeyAction.toggle &&
        action != _PlaybackKeyAction.catalog) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    _playbackKeyboard.heldKeys.add(key);
    if (_playbackKeyboard.selecting) return KeyEventResult.handled;
    switch (action) {
      case _PlaybackKeyAction.toggle:
        if (_playbackRequested) {
          unawaited(_pauseForRemoteControls());
        } else {
          _togglePlayback();
        }
      case _PlaybackKeyAction.controls:
        unawaited(_pauseForRemoteControls());
      case _PlaybackKeyAction.catalog:
        unawaited(_showRemoteCatalog());
      case _PlaybackKeyAction.backward:
      case _PlaybackKeyAction.forward:
        if (widget.duration > Duration.zero) {
          _seekBy(action == _PlaybackKeyAction.backward ? -10 : 10);
        }
      case _PlaybackKeyAction.previous:
      case _PlaybackKeyAction.next:
        unawaited(
          _selectKeyboardEpisode(
            widget.currentIndex +
                (action == _PlaybackKeyAction.previous ? -1 : 1),
          ),
        );
    }
    return KeyEventResult.handled;
  }

  Future<void> _selectKeyboardEpisode(int index) async {
    if (index < 0 || index >= widget.episodes.length) return;
    _playbackKeyboard.selecting = true;
    try {
      await _selectEpisode(index);
    } catch (error) {
      if (mounted) widget.onError(error);
    } finally {
      _playbackKeyboard.selecting = false;
    }
  }

  bool get _overlayOpen => _modalOpen || widget.interactionBlocked;
  bool get _playbackRequested =>
      widget.playing ||
      ((widget.player?.playWhenReady ?? false) &&
          !(widget.player?.completed ?? false));
}

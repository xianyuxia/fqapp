part of 'video_player_chrome.dart';

extension _VideoPlayerKeyboard on _VideoPlayerChromeState {
  KeyEventResult _handlePlaybackKey(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (isWindowsDesktop ||
        event.logicalKey != LogicalKeyboardKey.space ||
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
    if (focus?.widget is EditableText ||
        focus?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    // Consume repeats and key-up too, so a focused button cannot also activate.
    if (event is KeyDownEvent) _togglePlayback();
    return KeyEventResult.handled;
  }

  bool get _overlayOpen => _modalOpen || widget.interactionBlocked;
  bool get _playbackRequested =>
      widget.playing ||
      ((widget.player?.playWhenReady ?? false) &&
          !(widget.player?.completed ?? false));
}

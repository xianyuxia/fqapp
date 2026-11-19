part of 'video_player_chrome.dart';

extension _VideoPlayerRemote on _VideoPlayerChromeState {
  void _syncRemoteControls(VideoPlayerChrome old) {
    if (old.player != widget.player ||
        old.currentIndex != widget.currentIndex ||
        !old.playing && widget.playing ||
        !widget.enabled) {
      _playbackKeyboard.navigating = false;
    }
  }

  Future<void> _pauseForRemoteControls() async {
    final player = widget.player;
    _endBoost();
    _cancelSeek(resume: false);
    final interaction = ++_interaction;
    if (_playbackRequested) await _control((player) => player.pause());
    if (mounted && widget.player == player && interaction == _interaction) {
      _focusPageControls();
    }
  }

  void _focusPageControls() {
    _hideTimer?.cancel();
    _setRemoteState(() {
      _playbackKeyboard.navigating = true;
      _clearScreen = false;
      _visible = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_playbackKeyboard.navigating) return;
      final focus = _playbackKeyboard.play;
      if (focus.context != null && focus.canRequestFocus) {
        focus.requestFocus();
      } else {
        _playbackKeyboard.controls.nextFocus();
      }
    });
  }

  Widget _remotePageControls(Widget child) => FocusScope(
    node: _playbackKeyboard.controls,
    descendantsAreFocusable: widget.enabled && _appActive,
    child: child,
  );

  Widget _pausedPlayIcon(bool focusable) {
    final icon = Icon(
      Icons.play_arrow_rounded,
      size: 86,
      color: Colors.white.withValues(alpha: .2),
    );
    return Center(
      child: focusable && androidRemoteEnabled
          ? RemoteFocus(
              focusNode: _playbackKeyboard.play,
              onActivate: _togglePlayback,
              child: GestureDetector(onTap: _togglePlayback, child: icon),
            )
          : IgnorePointer(child: icon),
    );
  }

  Future<void> _showRemoteCatalog() async => _openPanel();

  Widget _transportButton(
    String tooltip,
    IconData icon,
    VoidCallback? onPressed,
  ) => SizedBox(
    width: 40,
    height: 48,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      focusNode: tooltip == '播放' || tooltip == '暂停'
          ? _playbackKeyboard.play
          : null,
      padding: EdgeInsets.zero,
      color: Colors.white,
      disabledColor: Colors.white24,
      icon: Icon(icon, size: 25),
    ),
  );
}

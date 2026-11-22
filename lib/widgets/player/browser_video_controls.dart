import 'package:material_ui/material_ui.dart';

/// Visible controls for browser video surfaces that otherwise rely on gestures.
class BrowserVideoControls extends StatelessWidget {
  const BrowserVideoControls({
    super.key,
    required this.playing,
    required this.onTogglePlayback,
    required this.onFullscreen,
    required this.seekBar,
    this.fullscreen = false,
  });

  final bool playing;
  final bool fullscreen;
  final VoidCallback? onTogglePlayback;
  final VoidCallback? onFullscreen;
  final Widget seekBar;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xA6000000),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        IconButton(
          tooltip: playing ? '暂停' : '播放',
          onPressed: onTogglePlayback,
          color: Colors.white,
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        Expanded(child: seekBar),
        IconButton(
          tooltip: fullscreen ? '退出全屏' : '全屏',
          onPressed: onFullscreen,
          color: Colors.white,
          icon: Icon(
            fullscreen ? Icons.fullscreen_exit : Icons.fullscreen_rounded,
          ),
        ),
      ],
    ),
  );
}

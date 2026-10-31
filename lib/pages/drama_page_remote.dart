part of 'drama_page.dart';

/// Long-press is the official two-branch gesture (`jq3/x$q.onLongPress`
/// `:2228-2262`）：命中横向中带（`K6()` `:2690-2711`，竖屏 50% / 横屏 33% 宽、
/// 居中、Y 不限）且 `y7()` 处理成功 → 打开更多面板；带外才是速度层的 2×
/// 快进，按住期间生效（`@string/ec6`=「2倍速快进中」，`cjx.xml`）。
///
/// **这里不再挂横向拖动。** 官方那张卡上左右滑是整屏调进度（`o.java:K6`，
/// `bottomMargin=138dp`），但这条手势和「横滑切频道」是同一个操作的两套语义，
/// 落在不同区域会互相打架。调进度收窄到底部进度条（`_SeekTrack` 自己带
/// 横向拖动）：卡片其余区域一律归外层 [TabSwipeArea] 切频道，左边滑是
/// 上一个频道、右边滑是下一个，不再随按下点在「调进度 / 切频道」之间跳。

class _CardGestures extends StatelessWidget {
  final VoidCallback? onMenu;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onPanelLongPress;
  final VoidCallback onBoostLongPressStart;
  final VoidCallback onBoostLongPressEnd;

  const _CardGestures({
    super.key,
    this.onMenu,
    required this.enabled,
    required this.onTap,
    required this.onPanelLongPress,
    required this.onBoostLongPressStart,
    required this.onBoostLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.expand();
    return LayoutBuilder(
      builder: (context, constraints) {
        // 官方 `jq3/x.K6()`：中带宽 = 视图宽 ×（竖屏 0.5 / 横屏 0.33），
        // 居中放置，Y 不限。横竖屏分档来自官方 `J6()`。
        final bandFraction =
            MediaQuery.orientationOf(context) == Orientation.landscape
            ? 0.33
            : 0.5;
        bool inBand(double dx) {
          final width = constraints.maxWidth;
          if (width <= 0) return false;
          final half = width * bandFraction / 2;
          final center = width / 2;
          return dx >= center - half && dx <= center + half;
        }

        return RemoteGestureDetector(
          key: const Key('drama_card_gestures'),
          // opaque：整块手势区自己吃指针，上滑翻页仍归外层 PageView 的竖直
          // 拖动；横向则留给更外层的 TabSwipeArea（这里没有横向识别器，
          // 竞技场里只剩它一个）。
          behavior: HitTestBehavior.opaque,
          // 没有双击手势了，单击立即派发（不再等双击窗口）。
          onTap: onTap,
          onMenu: onMenu,
          onLongPressStart: (details) {
            if (inBand(details.localPosition.dx)) {
              onPanelLongPress();
            } else {
              HapticFeedback.lightImpact();
              onBoostLongPressStart();
            }
          },
          // 带外快进的收尾由 endBoost 的 _boosting 门挡住：中带开面板的
          // 那支从未 startBoost，松手不能动速率。
          onLongPressEnd: (_) => onBoostLongPressEnd(),
          onLongPressCancel: onBoostLongPressEnd,
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

extension _DramaRemoteMenu on _DramaPageState {
  Widget _remoteFeedMenu(List<MediaItem> items, Widget child) => RemoteMenu(
    onMenu: _current.playsInline && !_modalOpen && items.isNotEmpty
        ? () =>
              _openQuickCatalog(items[_screenIndex.clamp(0, items.length - 1)])
        : null,
    child: child,
  );
}

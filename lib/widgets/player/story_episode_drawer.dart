part of 'story_player_panel.dart';

extension _StoryEpisodeDrawerView on _StoryEpisodeDrawerState {
  Widget _buildDrawer(BuildContext context) {
    final playingIndex = widget.playingIndex ?? widget.currentIndex;
    return Material(
      key: const ValueKey('story-episode-drawer'),
      color: const Color(0xFF141414),
      // 抽屉贴在右缘：横向只该让开**右侧**的安全区（右挖孔机型），左边
      // 那条是另一侧屏幕边缘的挖孔，套进来会把标题和格子整体推右。
      child: SafeArea(
        left: false,
        child: Column(
          children: [
            _drawerHeader(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // 4 列方格：宽 =（抽屉宽 − 左右 24 − 列距 3×8）/ 4。
                  _tile = (constraints.maxWidth - 24 - 24) / 4;
                  return GridView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 4,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1,
                        ),
                    itemCount: widget.episodes.length,
                    itemBuilder: (context, index) =>
                        _drawerEpisodeTile(index, playingIndex),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerHeader() => SizedBox(
    height: 64,
    child: Stack(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            key: const ValueKey('story-drawer-close'),
            tooltip: '关闭',
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ),
        const Align(
          alignment: Alignment.center,
          child: Text(
            '选集',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
        if (widget.onOpenRelatedSeries != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const ValueKey('story-drawer-related-series'),
              onPressed: widget.onOpenRelatedSeries,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: const Text('同系列'),
            ),
          ),
      ],
    ),
  );

  Widget _drawerEpisodeTile(int index, int playingIndex) {
    final active = index == playingIndex;
    final watched = !active && widget.watched.contains(index);
    return Semantics(
      key: ValueKey('story-episode-$index'),
      label: '第 ${index + 1} 集',
      value: active ? (widget.playing ? '正在播放' : '当前剧集') : null,
      button: true,
      selected: active,
      excludeSemantics: true,
      onTap: () => widget.onSelectEpisode(index),
      child: Material(
        color: active ? const Color(0xB3FA6725) : const Color(0x26FFFFFF),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        ),
        clipBehavior: Clip.antiAlias,
        child: RemoteInkWell(
          autofocus: _focusCurrent(index),
          onTap: () => widget.onSelectEpisode(index),
          child: Stack(
            children: [
              Center(
                child: Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: active ? FontWeight.bold : FontWeight.normal,
                    color: active
                        ? _currentText
                        : watched
                        ? const Color(0x66FFFFFF)
                        : Colors.white,
                  ),
                ),
              ),
              if (active)
                Positioned(
                  top: 4,
                  right: 4,
                  child: SizedBox(
                    width: 12,
                    height: 12,
                    child: Lottie.asset(
                      'assets/lottie/video_playing_orange.json',
                      animate: widget.playing,
                      repeat: true,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

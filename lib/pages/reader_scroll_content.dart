part of 'reader_page.dart';

extension _ReaderScrollContent on _ReaderPageState {
  Widget _buildScrollContent(
    ReaderChapterLayout layout,
    ReaderSelectionScope scope,
  ) {
    final spec = layout.spec;
    // The scroll list re-renders the measured span, so the bubble is already in
    // it. Its size still depends on this list's own constraints, and the
    // painter's placeholder was measured at spec.width — the same width, so the
    // two agree without a second measurement pass.
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth != 0) return false;
        if (notification is ScrollStartNotification) {
          // A new drag resets the bottom-overscroll accumulator, so only
          // one continuous-reading advance fires per drag past the end.
          _scrollOverscroll = 0;
          if (notification.dragDetails != null) {
            // Scrolling away cancels the selection (the official client keeps
            // it and repositions its toolbar after the scroll settles; here one
            // long press reselects instead).
            _closeSelectionBar(clearSelection: true);
            _hideControlsOnDrag();
          }
          return false;
        }
        if (notification is OverscrollNotification &&
            notification.dragDetails != null &&
            _preferences.continuousReading &&
            !_changingChapter &&
            !_loading) {
          // 连续阅读：滚动到底后继续往下拉，把下一章接上；滚到顶后继续
          // 往下拉，把上一章接上（落在上一章末尾）。章末按钮行仍在，
          // 点它一样能进上一章/下一章。Overscroll 带符号：底部为正、
          // 顶部为负；到不了的方向不累计，避免陈旧的累计量在反向时
          // 提前触发。
          final overscroll = notification.overscroll;
          final canAdvance = _index < widget.chapters.length - 1;
          final canRetreat = _index > 0;
          if ((overscroll > 0 && canAdvance) ||
              (overscroll < 0 && canRetreat)) {
            _scrollOverscroll += overscroll;
            if (_scrollOverscroll > 32) {
              _scrollOverscroll = 0;
              unawaited(_next());
            } else if (_scrollOverscroll < -32) {
              _scrollOverscroll = 0;
              unawaited(_prev(startAtEnd: true));
            }
          }
        }
        return false;
      },
      child: ListView.builder(
        key: const ValueKey('reader-paragraph-list'),
        controller: _scrollController,
        padding: EdgeInsets.fromLTRB(
          spec.horizontalPadding,
          spec.verticalPadding,
          spec.horizontalPadding,
          spec.verticalPadding + 32,
        ),
        itemCount: layout.blocks.length + 1,
        // Exact extents let a distant saved text position restore in one frame;
        // a lazy variable-height list otherwise only estimates its scroll range.
        itemExtentBuilder: (index, _) => index < layout.blocks.length
            ? layout.blocks[index].lines.isEmpty
                  ? 0
                  : layout.blocks[index].height + spec.paragraphSpacing
            : spec.footerHeight,
        itemBuilder: (context, itemIndex) {
          if (itemIndex < layout.blocks.length) {
            if (layout.blocks[itemIndex].lines.isEmpty) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: EdgeInsets.only(bottom: spec.paragraphSpacing),
              child: ReaderBlockContent(
                block: layout.blocks[itemIndex],
                spec: spec,
                imageProviderFactory: widget.imageProviderFactory,
                selectionScope: scope,
                selection: _selection,
                rangeUnderlines: _displayRangeUnderlines,
                narrationRange: _narrationRange,
                onParagraphLongPress: (block, position) =>
                    unawaited(_onParagraphLongPress(block, position)),
                onParagraphLongPressMoveUpdate: _onParagraphLongPressMoveUpdate,
                onParagraphLongPressEnd: _onParagraphLongPressEnd,
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(LucideIcons.chevron_left, size: 18),
                    label: const Text(
                      '上一章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, height: 1.4),
                    ),
                    onPressed: _index > 0 ? _prev : null,
                  ),
                ),
                const SizedBox(width: 16),
                if (_ideas.isNotEmpty)
                  OutlinedButton.icon(
                    key: const ValueKey('reader-scroll-chapter-comments'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => unawaited(
                      _showIdeas(focusParaIndex: _chapterEndParagraph()),
                    ),
                    icon: const Icon(LucideIcons.message_square, size: 18),
                    label: Text(
                      '本章评论 ${_ideas.total}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                  ),
                if (_ideas.isNotEmpty) const SizedBox(width: 16),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(LucideIcons.chevron_right, size: 18),
                    label: const Text(
                      '下一章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, height: 1.4),
                    ),
                    onPressed: _index < widget.chapters.length - 1
                        ? _next
                        : null,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

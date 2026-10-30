import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/chapter_text_formatter.dart';
import '../../services/text_replacement_engine.dart';
import 'reader_chapter_layout.dart';

class JoinedReaderChapter {
  const JoinedReaderChapter(
    this.text,
    this.content,
    this.replacement,
    this.layout,
  );
  final String text;
  final ChapterContent content;
  final TextReplacementResult? replacement;
  final ReaderChapterLayout layout;

  JoinedReaderChapter withLayout(ReaderChapterLayout value) =>
      JoinedReaderChapter(text, content, replacement, value);
}

class JoinedReaderPosition {
  const JoinedReaderPosition(this.index, this.chapter, this.scroll, this.start);
  final int index;
  final JoinedReaderChapter chapter;
  final double scroll;
  final double start;
}

/// A bounded window of measured chapters. Extending either end preserves the
/// visible text; positions exposed to history always remain chapter-relative.
class ReaderJoinedScroll extends StatefulWidget {
  const ReaderJoinedScroll({
    super.key,
    required this.controller,
    required this.index,
    required this.chapter,
    required this.chapterCount,
    required this.loader,
    required this.onPosition,
    required this.onDragStart,
    required this.blockBuilder,
  });

  final ScrollController controller;
  final int index;
  final JoinedReaderChapter chapter;
  final int chapterCount;
  final Future<JoinedReaderChapter> Function(int, ReaderLayoutSpec) loader;
  final ValueChanged<JoinedReaderPosition> onPosition;
  final VoidCallback onDragStart;
  final Widget Function(int, ReaderChapterLayout, ReaderContentBlock)
  blockBuilder;

  @override
  State<ReaderJoinedScroll> createState() => ReaderJoinedScrollState();
}

class ReaderJoinedScrollState extends State<ReaderJoinedScroll> {
  static const _dividerHeight = 56.0;
  final _chapters = <int, JoinedReaderChapter>{};
  final _pending = <int>{};
  final _errors = <int>{};
  int _generation = 0;
  bool _adjusting = false;
  bool _scheduled = false;
  double? _pendingOffset;
  int _restoreRevision = 0;

  List<int> get _indices => _chapters.keys.toList()..sort();
  JoinedReaderChapter? chapterAt(int index) => _chapters[index];

  double _height(JoinedReaderChapter chapter) =>
      chapter.layout.contentHeight +
      chapter.layout.spec.verticalPadding * 2 +
      _dividerHeight;

  double chapterStart(int index) {
    var start = 0.0;
    for (final i in _indices) {
      if (i >= index) break;
      start += _height(_chapters[i]!);
    }
    return start;
  }

  JoinedReaderPosition? get position {
    if (!widget.controller.hasClients || _chapters.isEmpty) return null;
    final pixels = _pendingOffset ?? widget.controller.offset;
    var start = 0.0;
    final indices = _indices;
    for (final index in indices) {
      final chapter = _chapters[index]!;
      if (pixels < start + _height(chapter) || index == indices.last) {
        return JoinedReaderPosition(
          index,
          chapter,
          math.max(0, pixels - start),
          start,
        );
      }
      start += _height(chapter);
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _chapters[widget.index] = widget.chapter;
    widget.controller.addListener(_schedulePosition);
    _schedulePosition();
  }

  @override
  void dispose() {
    ++_generation;
    widget.controller.removeListener(_schedulePosition);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ReaderJoinedScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    final spec = widget.chapter.layout.spec;
    if (oldWidget.chapter.layout.spec != spec ||
        oldWidget.index == widget.index &&
            (oldWidget.chapter.text != widget.chapter.text ||
                oldWidget.chapter.replacement != widget.chapter.replacement)) {
      // A font/width/replacement change invalidates adjacent measurements.
      ++_generation;
      _pending.clear();
      _errors.clear();
      _chapters.clear();
      _chapters[widget.index] = widget.chapter;
    } else {
      final before = position;
      if (oldWidget.index != widget.index) {
        final outgoing = _chapters[oldWidget.index];
        if (outgoing != null) {
          _chapters[oldWidget.index] = outgoing.withLayout(
            ReaderChapterLayout(
              title: outgoing.layout.blocks.first.text,
              content: outgoing.content,
              replacement: outgoing.replacement,
              spec: spec,
            ),
          );
        }
      }
      _chapters[widget.index] = widget.chapter;
      if (before != null &&
          _chapters.containsKey(before.index) &&
          (oldWidget.index != widget.index ||
              !identical(oldWidget.chapter.layout, widget.chapter.layout))) {
        final textOffset = before.chapter.layout.textOffsetAtScroll(
          before.scroll,
        );
        _restoreAfterLayout(
          chapterStart(before.index) +
              _chapters[before.index]!.layout.scrollForTextOffset(textOffset) +
              before.scroll -
              before.chapter.layout.scrollForTextOffset(textOffset),
        );
      }
    }
    _schedulePosition();
  }

  void jumpToChapterOffset(int index, double offset) {
    if (!widget.controller.hasClients) return;
    if (_adjusting) {
      _restoreAfterLayout(chapterStart(index) + offset);
      return;
    }
    widget.controller.jumpTo(
      (chapterStart(index) + offset).clamp(
        0,
        widget.controller.position.maxScrollExtent,
      ),
    );
  }

  void _restoreAfterLayout(double offset) {
    _adjusting = true;
    _pendingOffset = offset;
    final revision = ++_restoreRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _restoreRevision) return;
      _pendingOffset = null;
      if (widget.controller.hasClients) {
        widget.controller.jumpTo(
          offset.clamp(0, widget.controller.position.maxScrollExtent),
        );
      }
      _adjusting = false;
      _schedulePosition();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _schedulePosition() {
    if (_scheduled || _adjusting) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || _adjusting) return;
      final current = position;
      if (current == null) return;
      widget.onPosition(current);
      final indices = _indices;
      final viewport = widget.controller.position.viewportDimension;
      final offset = widget.controller.offset;
      if (indices.first == current.index ||
          offset - chapterStart(indices.first) < viewport) {
        unawaited(_load(indices.first - 1));
      }
      if (indices.last == current.index ||
          widget.controller.position.extentAfter < viewport * 2) {
        unawaited(_load(indices.last + 1));
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _load(int index) async {
    final active = position?.index ?? widget.index;
    final needsMoreText =
        widget.controller.hasClients &&
        widget.controller.position.extentAfter <
            widget.controller.position.viewportDimension * 2;
    if (index < 0 ||
        index >= widget.chapterCount ||
        (index < active - 2 || index > active + 2 && !needsMoreText) ||
        _chapters.containsKey(index) ||
        _pending.contains(index) ||
        _errors.contains(index)) {
      return;
    }
    final generation = _generation;
    final spec = widget.chapter.layout.spec;
    setState(() => _pending.add(index));
    try {
      final chapter = await widget.loader(index, spec);
      if (!mounted || generation != _generation) return;
      final before = position;
      final oldStart = before?.start ?? 0;
      final oldOffset = before == null ? 0.0 : before.start + before.scroll;
      setState(() {
        _pending.remove(index);
        _chapters[index] = chapter;
        // Keep two neighbours plus enough short chapters to fill the viewport.
        if (before != null) {
          final end =
              chapterStart(before.index) +
              before.scroll +
              widget.controller.position.viewportDimension * 3;
          final remove = _indices
              .where(
                (i) =>
                    i < before.index - 2 ||
                    i > before.index + 2 && chapterStart(i) > end,
              )
              .toList();
          for (final i in remove) {
            _chapters.remove(i);
          }
        }
      });
      final delta = before == null ? 0 : chapterStart(before.index) - oldStart;
      _restoreAfterLayout(oldOffset + delta);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _pending.remove(index);
        _errors.add(index);
      });
    }
  }

  Widget _boundary(int index) {
    if (index < 0 || index >= widget.chapterCount) {
      return Center(child: Text(index < 0 ? '全书开始' : '全书完'));
    }
    if (_pending.contains(index)) {
      return const Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Center(
      child: TextButton(
        onPressed: () {
          _errors.remove(index);
          unawaited(_load(index));
        },
        child: Text(_errors.contains(index) ? '章节加载失败，点击重试' : '加载相邻章节'),
      ),
    );
  }

  Widget _buildRow(
    ({int index, ReaderContentBlock? block, double height}) row,
    ReaderLayoutSpec spec,
  ) {
    if (row.height == 0) return const SizedBox.shrink();
    if (row.block case final block?) {
      return Padding(
        padding: EdgeInsets.only(bottom: spec.paragraphSpacing),
        child: widget.blockBuilder(
          row.index,
          _chapters[row.index]!.layout,
          block,
        ),
      );
    }
    if (row.height == spec.verticalPadding) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: spec.verticalPadding),
      child: Row(
        key: ValueKey('reader-chapter-divider-${row.index}'),
        children: [
          const Expanded(child: Divider()),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('本章完', style: TextStyle(fontSize: 12)),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final indices = _indices;
    final spec = widget.chapter.layout.spec;
    final rows = <({int index, ReaderContentBlock? block, double height})>[];
    // The upper boundary occupies zero scroll space unless it needs an action.
    for (final index in indices) {
      final layout = _chapters[index]!.layout;
      rows.add((index: index, block: null, height: spec.verticalPadding));
      for (final block in layout.blocks) {
        rows.add((
          index: index,
          block: block,
          height: block.lines.isEmpty
              ? 0
              : block.height + spec.paragraphSpacing,
        ));
      }
      rows.add((
        index: index,
        block: null,
        height: spec.verticalPadding + _dividerHeight,
      ));
    }
    return NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 && notification.dragDetails != null) {
          widget.onDragStart();
        }
        return false;
      },
      child: Stack(
        children: [
          CustomScrollView(
            key: const ValueKey('reader-joined-paragraph-list'),
            controller: widget.controller,
            slivers: [
              SliverPadding(
                padding: EdgeInsets.symmetric(
                  horizontal: spec.horizontalPadding,
                ),
                sliver: SliverVariedExtentList(
                  itemExtentBuilder: (i, _) =>
                      i < rows.length ? rows[i].height : _dividerHeight,
                  delegate: _MeasuredChapterDelegate(
                    (context, i) {
                      if (i == rows.length) return _boundary(indices.last + 1);
                      return _buildRow(rows[i], spec);
                    },
                    childCount: rows.length + 1,
                    extent: rows.fold<double>(
                      _dividerHeight,
                      (sum, row) => sum + row.height,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_errors.contains(indices.first - 1) ||
              _pending.contains(indices.first - 1))
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: _dividerHeight,
              child: _boundary(indices.first - 1),
            ),
        ],
      ),
    );
  }
}

// Exact bounds are essential when prepending chapters or restoring a distant
// position. Flutter's default delegate extrapolates from only visible rows.
class _MeasuredChapterDelegate extends SliverChildBuilderDelegate {
  _MeasuredChapterDelegate(
    super.builder, {
    required super.childCount,
    required this.extent,
  });
  final double extent;
  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => extent;
}

import 'package:flutter/material.dart';

import '../../services/reader_preferences.dart';

class ReaderScrollModeSetting extends StatelessWidget {
  const ReaderScrollModeSetting({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final ReaderScrollChapterMode value;
  final ValueChanged<ReaderScrollChapterMode> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('reader-scroll-chapter-mode'),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('滚动跨章方式'),
        const Text('仅上下滚动生效', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final mode in ReaderScrollChapterMode.values)
              ChoiceChip(
                label: Text(
                  mode == ReaderScrollChapterMode.replace
                      ? '直接切换下一章'
                      : '分割线拼接章节',
                ),
                selected: value == mode,
                onSelected: (_) => onChanged(mode),
              ),
          ],
        ),
      ],
    ),
  );
}

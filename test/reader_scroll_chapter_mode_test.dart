import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/pages/reader_page.dart';
import 'package:fqapp/services/reader_preferences.dart';
import 'package:fqapp/widgets/reader/reader_joined_scroll.dart';
import 'package:fqapp/widgets/reader/reader_scroll_mode_setting.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'reader_page_mode': 'scroll',
      'reader_scroll_chapter_mode': 'joined',
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (_) async => null,
        );
  });

  test(
    'chapter mode defaults safely and survives other preference changes',
    () async {
      SharedPreferences.setMockInitialValues({});
      expect(
        (await ReaderPreferences.load()).scrollChapterMode,
        ReaderScrollChapterMode.replace,
      );
      await const ReaderPreferences(
        scrollChapterMode: ReaderScrollChapterMode.joined,
      ).copyWith(fontSize: 24).save();
      expect(
        (await ReaderPreferences.load()).scrollChapterMode,
        ReaderScrollChapterMode.joined,
      );
      SharedPreferences.setMockInitialValues({
        'reader_scroll_chapter_mode': 'unknown',
      });
      expect(
        (await ReaderPreferences.load()).scrollChapterMode,
        ReaderScrollChapterMode.replace,
      );
    },
  );

  testWidgets(
    'joined chapters preserve endings, save local progress and restore',
    (tester) async {
      final store = MemoryReaderStore();
      await _mountReader(tester, store);
      var state = tester.state<ReaderJoinedScrollState>(
        find.byType(ReaderJoinedScroll),
      );
      expect(state.chapterAt(1), isNotNull);
      final start = state.chapterStart(1);
      state.widget.controller.jumpTo(start - 100);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-chapter-divider-0')),
        findsOneWidget,
      );
      expect(find.text('章 1', findRichText: true), findsOneWidget);
      state.jumpToChapterOffset(1, 240);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(store.entry?['chapterId'], 'c1');
      expect(store.entry?['episode'], 1);
      final textOffset = store.entry!['textOffset'] as int;
      expect(textOffset, greaterThan(0));
      expect((store.entry!['position'] as num).toDouble(), closeTo(240, 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(_readerApp(store, start: 1));
      await tester.pumpAndSettle();
      state = tester.state<ReaderJoinedScrollState>(
        find.byType(ReaderJoinedScroll),
      );
      expect(state.position?.index, 1);
      expect(store.entry?['chapterId'], 'c1');
      expect(store.entry?['textOffset'], textOffset);
      state.jumpToChapterOffset(0, 160);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(store.entry?['chapterId'], 'c0');
      expect(store.entry?['episode'], 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed next chapter keeps current text and can retry', (
    tester,
  ) async {
    var fail = true;
    final store = MemoryReaderStore();
    await _mountReader(
      tester,
      store,
      loader: (chapter) async {
        if (chapter.itemId == 'c1' && fail) throw StateError('offline');
        return _text(chapter);
      },
    );
    final state = tester.state<ReaderJoinedScrollState>(
      find.byType(ReaderJoinedScroll),
    );
    state.widget.controller.jumpTo(
      state.widget.controller.position.maxScrollExtent,
    );
    await tester.pumpAndSettle();
    expect(find.text('章节加载失败，点击重试'), findsOneWidget);
    expect(store.entry?['chapterId'], 'c0');
    fail = false;
    await tester.tap(find.text('章节加载失败，点击重试'));
    await tester.pumpAndSettle();
    expect(state.chapterAt(1), isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long reading evicts old chapters and resizing preserves the chapter',
    (tester) async {
      final store = MemoryReaderStore();
      await _mountReader(tester, store);
      final state = tester.state<ReaderJoinedScrollState>(
        find.byType(ReaderJoinedScroll),
      );
      for (var i = 1; i <= 6; i++) {
        expect(state.chapterAt(i), isNotNull);
        state.jumpToChapterOffset(i, 400);
        await tester.pumpAndSettle();
        expect(state.position?.index, i);
        expect(store.entry?['chapterId'], 'c$i');
      }
      expect(state.chapterAt(0), isNull);
      expect(
        List.generate(
          8,
          state.chapterAt,
        ).whereType<JoinedReaderChapter>().length,
        lessThanOrEqualTo(5),
      );
      final offset = store.entry?['textOffset'];
      await tester.binding.setSurfaceSize(const Size(560, 400));
      await tester.pumpAndSettle();
      expect(state.position?.index, 6);
      expect(store.entry?['chapterId'], 'c6');
      final layout = state.chapterAt(6)!.layout;
      final block = layout.blockAtOffset(offset as int)!;
      final line = block.lines.firstWhere(
        (line) =>
            block.start + line.start <= offset &&
            block.start + line.end >= offset,
      );
      // A wider line starts earlier; the old anchor must still be on that line.
      expect(store.entry?['textOffset'], block.start + line.start);
      state.jumpToChapterOffset(5, 120);
      await tester.pumpAndSettle();
      expect(store.entry?['chapterId'], 'c5');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'chapter options remain usable with large text in a narrow window',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(280, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var mode = ReaderScrollChapterMode.replace;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: ReaderScrollModeSetting(
                value: mode,
                onChanged: (value) => mode = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('分割线拼接章节'));
      await tester.pumpAndSettle();
      expect(mode, ReaderScrollChapterMode.joined);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('short chapters keep appending until there is room to scroll', (
    tester,
  ) async {
    final store = MemoryReaderStore();
    await _mountReader(
      tester,
      store,
      loader: (chapter) async => '${chapter.title} 的简短正文。',
    );
    final state = tester.state<ReaderJoinedScrollState>(
      find.byType(ReaderJoinedScroll),
    );
    expect(state.chapterAt(3), isNotNull);
    expect(state.widget.controller.position.maxScrollExtent, greaterThan(0));
    state.widget.controller.jumpTo(
      state.widget.controller.position.maxScrollExtent,
    );
    await tester.pumpAndSettle();
    expect(state.position!.index, greaterThan(0));
    expect(tester.takeException(), isNull);
  });
}

Future<void> _mountReader(
  WidgetTester tester,
  MemoryReaderStore store, {
  ChapterTextLoader? loader,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.binding.setSurfaceSize(const Size(400, 600));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(_readerApp(store, loader: loader));
  await tester.pumpAndSettle();
}

String _text(Chapter chapter) => List.generate(
  35,
  (i) => '${chapter.title} 第 $i 段，连续阅读需要完整保留前一章的结尾和下一章开头。',
).join('\n\n');

Widget _readerApp(
  MemoryReaderStore store, {
  int start = 0,
  ChapterTextLoader? loader,
}) => MaterialApp(
  theme: ThemeData(splashFactory: NoSplash.splashFactory),
  home: ReaderPage(
    bookId: 'joined-test',
    title: '拼接测试',
    startIndex: start,
    chapters: List.generate(
      8,
      (i) => Chapter(itemId: 'c$i', title: '章 $i', volumeName: '正文'),
    ),
    readerStore: store,
    chapterCache: MemoryChapterCache(),
    chapterLoader: loader ?? (chapter) async => _text(chapter),
  ),
);

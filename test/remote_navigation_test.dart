import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/widgets/remote_focus.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/series_detail/series_detail_episodes.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';
import 'package:fqapp/widgets/lazy_indexed_stack.dart';

void main() {
  testWidgets(
    'app overlay outlines native controls without altering activation',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => RemoteFocusOverlay(child: child!),
          home: Scaffold(
            body: Center(
              child: TextButton(
                autofocus: true,
                onPressed: () => calls++,
                child: const Text('native control'),
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.byKey(const ValueKey('remote-active-focus')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('opaque cards keep a visible focus frame above their contents', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Material(
            child: RemoteInkWell(
              focusNode: focus,
              onTap: () {},
              child: Container(
                width: 200,
                height: 80,
                color: Colors.white,
                child: const Text('opaque'),
              ),
            ),
          ),
        ),
      ),
    );
    focus.requestFocus();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-focus-ring')), findsOneWidget);
    expect(focus.hasPrimaryFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('menu on a non-video channel is ignored safely', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteMenu(
          child: TextButton(
            autofocus: true,
            onPressed: () {},
            child: const Text('browse'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    expect(tester.takeException(), isNull);
  });

  testWidgets('changing menu availability retains the child state', (
    tester,
  ) async {
    var enabled = true;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return RemoteMenu(
                onMenu: enabled ? () {} : null,
                child: const TextField(),
              );
            },
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '保留内容');
    update(() => enabled = false);
    await tester.pump();
    expect(find.text('保留内容'), findsOneWidget);
  });

  testWidgets('menu is available from any focused feed control', (
    tester,
  ) async {
    var menus = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteMenu(
          onMenu: () => menus++,
          child: TextButton(
            autofocus: true,
            onPressed: () {},
            child: const Text('feed action'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    expect(menus, 1);
  });

  testWidgets(
    'direction keys reach short-drama tab and confirmation activates its card',
    (tester) async {
      var selected = 0;
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: HomeTabBar(
                      selectedIndex: selected,
                      onSelect: (index) => setState(() => selected = index),
                    ),
                  ),
                  if (selected == 2)
                    SliverToBoxAdapter(
                      child: RemoteGestureDetector(
                        key: const ValueKey('short-drama-card'),
                        onTap: () => opened = true,
                        child: const SizedBox(
                          height: 100,
                          child: Center(child: Text('测试短剧')),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      // First direction press enters focus navigation without a pointer or Tab.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('home_category_2')),
          matching: find.byKey(const ValueKey('remote-focus-ring')),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(selected, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(opened, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail episodes can be selected and expanded using only directions',
    (tester) async {
      final selected = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SeriesDetailEpisodes(
                episodes: List.generate(
                  50,
                  (i) => Chapter(itemId: '$i', title: '第 $i 集', volumeName: ''),
                ),
                currentIndex: 0,
                watched: const {},
                initialRange: 0,
                pageSize: 50,
                statusText: null,
                hasRelatedSeries: false,
                onOpenRelatedSeries: () {},
                loading: false,
                failed: false,
                onRetry: () {},
                onSelect: selected.add,
              ),
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(selected, [1]);
      for (var row = 0; row < 4; row++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('series-episode-49')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('touch input hides the remote-only focus frame', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RemoteFocus(
            focusNode: focus,
            autofocus: true,
            onActivate: () {},
            child: const SizedBox(width: 100, height: 60),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-focus-ring')), findsOneWidget);
    await tester.tapAt(const Offset(300, 300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('remote-focus-ring')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('focused touch actions consume confirmation repeats only once', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteFocus(
          autofocus: true,
          onActivate: () => calls++,
          child: const SizedBox(width: 100, height: 60),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(calls, 1);
  });

  testWidgets('hidden retained tabs cannot receive focus', (tester) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    var current = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return LazyIndexedStack(
              index: current,
              children: [
                TextButton(
                  focusNode: first,
                  onPressed: () {},
                  child: const Text('first'),
                ),
                TextButton(
                  focusNode: second,
                  onPressed: () {},
                  child: const Text('second'),
                ),
              ],
            );
          },
        ),
      ),
    );
    update(() => current = 1);
    await tester.pump();
    expect(first.canRequestFocus, isFalse);
    second.requestFocus();
    await tester.pump();
    expect(second.hasPrimaryFocus, isTrue);
    update(() => current = 0);
    await tester.pump();
    expect(second.canRequestFocus, isFalse);
    first.requestFocus();
    await tester.pump();
    expect(first.hasPrimaryFocus, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

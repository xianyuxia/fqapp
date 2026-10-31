import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/search_page.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';
import 'package:fqapp/widgets/remote_focus.dart';
import 'package:fqapp/widgets/remote_navigation.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('category focus frame leaves room around its label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => RemoteFocusOverlay(child: child!),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverPersistentHeader(
                delegate: HomeTabBarDelegate(
                  selectedIndex: 2,
                  onSelect: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final tab = find.byKey(const ValueKey('home_category_2'));
    final ring = find.descendant(
      of: tab,
      matching: find.byKey(const ValueKey('remote-focus-ring')),
    );
    expect(tester.getSize(ring).width, greaterThanOrEqualTo(48));
    expect(
      tester.getSize(ring).width,
      closeTo(tester.getSize(tab).width + 20, .1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'menu focuses the current dock item, arrows and confirm switch tabs',
    (tester) async {
      final dock = RemoteDockFocus();
      addTearDown(dock.dispose);
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => RemoteDockMenu(
              dock: dock,
              index: selected,
              enabled: true,
              child: Scaffold(
                extendBody: true,
                body: Stack(
                  children: [
                    Center(
                      child: TextButton(
                        onPressed: () {},
                        child: const Text('content'),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 150,
                      child: TextButton(
                        onPressed: () => fail('focus escaped behind dock'),
                        child: const Text('under dock'),
                      ),
                    ),
                  ],
                ),
                bottomNavigationBar: _changingDockParent(
                  selected,
                  dock.wrap(
                    NavigationBar(
                      selectedIndex: selected,
                      onDestinationSelected: (value) {
                        dock.preserveOnSwitch(value);
                        setState(() => selected = value);
                      },
                      destinations: remoteRootDestinations,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(_focusedDestination(), '首页');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(_focusedDestination(), '短剧');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(_focusedDestination(), '书架');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(_focusedDestination(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(_focusedDestination(), '书架');
    },
  );

  testWidgets('remote traversal skips back while touch back stays available', (
    tester,
  ) async {
    var backs = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              RemoteBackButton(
                tooltip: '返回',
                icon: const BackButtonIcon(),
                onPressed: () => backs++,
              ),
              TextButton(onPressed: () {}, child: const Text('内容')),
            ],
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<RemoteBackButton>(),
      isNull,
    );
    expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<RemoteBackButton>(),
      isNull,
    );
    await tester.tap(find.byTooltip('返回'));
    expect(backs, 1);
  });

  testWidgets(
    'opening search gives the input field focus before other controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                autofocus: true,
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SearchPage(
                      searchLoader:
                          (_, {required tabType, required offset}) async => [],
                    ),
                  ),
                ),
                child: const Text('首页搜索'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.focusNode.hasPrimaryFocus, isTrue);
      expect(find.byType(RemoteBackControl), findsOneWidget);
      await tester.enterText(find.byType(TextField), '短剧');
      expect(editable.controller.text, '短剧');
      expect(tester.takeException(), isNull);
    },
  );
}

String? _focusedDestination() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<NavigationDestination>()
    ?.label;

// The real shell changes from a blurred dock to a static dock for short dramas.
Widget _changingDockParent(int index, Widget child) =>
    index == 1 ? Padding(padding: EdgeInsets.zero, child: child) : child;

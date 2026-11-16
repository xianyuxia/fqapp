import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/widgets/lazy_indexed_stack.dart';
import 'package:fqapp/widgets/classic_shell_dock.dart';
import 'package:fqapp/widgets/remote_feed_navigation.dart';
import 'package:fqapp/widgets/remote_focus.dart';
import 'package:fqapp/widgets/remote_navigation.dart';
import 'package:fqapp/widgets/remote_root_navigation.dart';

void main() {
  late StreamController<bool> devices;
  var connected = true;
  setUp(() {
    connected = true;
    devices = StreamController<bool>.broadcast();
    PlatformChannels.invoke = (channel, method, args) async => connected;
    PlatformChannels.events = (_) => devices.stream;
  });
  tearDown(() async {
    PlatformChannels.invoke = null;
    PlatformChannels.events = null;
    await devices.close();
  });

  testWidgets('connected remote starts on dock and arrows switch without OK', (
    tester,
  ) async {
    final state = await _mount(tester);
    expect(_destination(), '首页');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(state.index, 1);
    expect(_destination(), '短剧');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(state.index, 2);
    expect(_destination(), '书架');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(state.index, 1);
    expect(_destination(), '短剧');
  });

  testWidgets('Up enters feed; Back returns to the same dock destination', (
    tester,
  ) async {
    final state = await _mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(_destination(), isNull);
    expect(_action(), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(state.calls, [0]);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(state.index, 1);
    expect(_destination(), '短剧');
  });

  testWidgets('feed Up/Down change dramas; sides only select the action row', (
    tester,
  ) async {
    final state = await _mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(state.drama, 1);
    expect(_action(), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_action(), 1);
    expect(state.calls, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(state.calls, [1]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_action(), 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_action(), 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pumpAndSettle();
    expect(state.calls, [1]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(state.drama, 0);
    expect(_action(), 0);
  });

  testWidgets('held Up used to enter the feed does not also skip a drama', (
    tester,
  ) async {
    final state = await _mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(state.drama, 0);
    expect(_action(), 0);
  });

  testWidgets(
    'touch-only launch keeps content focus and Menu does not move it',
    (tester) async {
      connected = false;
      await _mount(tester);
      final before = FocusManager.instance.primaryFocus;
      expect(_destination(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(before));
      devices.add(true);
      await tester.pumpAndSettle();
      expect(_destination(), '首页');
    },
  );

  testWidgets('a pushed page handles Back before root navigation', (
    tester,
  ) async {
    await _mount(tester);
    final context = tester.element(find.text('page-0'));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('detail route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('detail route'), findsNothing);
    expect(_destination(), '首页');
    expect(tester.takeException(), isNull);
  });
}

String? _destination() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<Semantics>()
    ?.properties
    .label;
int? _action() => FocusManager.instance.primaryFocus?.context
    ?.findAncestorWidgetOfExactType<RemoteFeedAction>()
    ?.index;

Future<_ShellState> _mount(WidgetTester tester) async {
  final key = GlobalKey<_ShellState>();
  await tester.pumpWidget(MaterialApp(home: _Shell(key: key)));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  return key.currentState!;
}

class _Shell extends StatefulWidget {
  const _Shell({super.key});
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  final dock = RemoteDockFocus();
  int index = 0;
  int drama = 0;
  final calls = <int>[];
  void select(int next) {
    dock.preserveOnSwitch(next);
    setState(() => index = next);
  }

  @override
  void dispose() {
    dock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RemoteRootNavigation(
    dock: dock,
    index: index,
    onSelect: select,
    child: Scaffold(
      extendBody: true,
      body: RemoteContentArea(
        child: LazyIndexedStack(
          index: index,
          children: [
            for (var tab = 0; tab < 4; tab++)
              tab == 1
                  ? RemoteFeedNavigation(
                      enabled: true,
                      onOpen: () => calls.add(0),
                      onStep: (delta) async => setState(() => drama += delta),
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var action = 0; action < 3; action++)
                              RemoteFeedAction(
                                index: action,
                                child: RemoteGestureDetector(
                                  onTap: () => calls.add(action),
                                  child: SizedBox(
                                    width: 100,
                                    height: 60,
                                    child: Text('action-$action'),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                  : Center(
                      child: TextButton(
                        onPressed: () {},
                        child: Text('page-$tab'),
                      ),
                    ),
          ],
        ),
      ),
      bottomNavigationBar: index == 1
          ? Padding(padding: EdgeInsets.zero, child: _bar())
          : ClipRect(child: _bar()),
    ),
  );
  Widget _bar() => dock.wrap(
    ClassicShellDock(
      selectedIndex: index,
      onSelected: select,
      overVideo: index == 1,
    ),
  );
}

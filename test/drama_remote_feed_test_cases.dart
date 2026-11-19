part of 'drama_inline_playback_test.dart';

void _registerRemoteFeedTests() {
  Future<void> enter(WidgetTester tester, _Session session) async {
    await _mount(tester, session);
    for (var n = 0; n < 5; n++) {
      await _flush(tester);
    }
    final action = FocusManager.instance.rootScope.traversalDescendants
        .firstWhere(
          (node) =>
              node.canRequestFocus &&
              node.context
                      ?.findAncestorWidgetOfExactType<RemoteFeedAction>()
                      ?.index ==
                  0,
        );
    action.requestFocus();
    await _flush(tester);
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    for (var n = 0; n < 20; n++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _flush(tester);
  }

  testWidgets(
    'remote recommendation Up/Down switch dramas instead of episodes',
    (tester) async {
      final session = _Session()..episodeCount = 3;
      await enter(tester, session);
      expect(session.directoryCalls, contains('16-0:短剧'));
      await key(tester, LogicalKeyboardKey.arrowDown);
      expect(
        tester
            .widget<PageView>(find.byKey(const Key('drama_feed')))
            .controller!
            .page,
        closeTo(1, .01),
      );
      expect(session.directoryCalls, contains('16-1:短剧'));
      expect(
        session.contentCalls.where((call) => call.startsWith('16-0-2:')),
        isEmpty,
      );
      await key(tester, LogicalKeyboardKey.arrowUp);
      expect(
        tester
            .widget<PageView>(find.byKey(const Key('drama_feed')))
            .controller!
            .page,
        closeTo(0, .01),
      );
      expect(find.byKey(const Key('drama_feed')), findsOneWidget);
      await key(tester, LogicalKeyboardKey.contextMenu);
      expect(find.byType(PlayletQuickCatalogSheet), findsNothing);
      expect(find.byType(PlayerPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'remote feed right selects the existing catalog button; OK opens it',
    (tester) async {
      await enter(tester, _Session()..episodeCount = 3);
      await key(tester, LogicalKeyboardKey.arrowRight);
      final selected = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<RemoteFeedAction>();
      expect(selected?.index, 1);
      await key(tester, LogicalKeyboardKey.select);
      expect(find.byType(PlayletQuickCatalogSheet), findsOneWidget);
      expect(find.byType(PlayerPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('remote feed default OK opens the current drama player', (
    tester,
  ) async {
    await enter(tester, _Session()..episodeCount = 3);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(find.byType(PlayletQuickCatalogSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

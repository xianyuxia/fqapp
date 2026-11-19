import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';
import 'package:fqapp/widgets/player/story_player_panel.dart';
import 'support/fakes.dart';
import 'package:fqapp/widgets/remote_focus.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fqapp/native_player'),
          (_) async => null,
        );
  });

  testWidgets(
    'confirmation release after closing episodes cannot activate the old focus',
    (tester) async {
      final focus = FocusNode();
      var oldButtonPresses = 0;
      addTearDown(focus.dispose);
      await _mount(
        tester,
        child: TextButton(
          focusNode: focus,
          onPressed: () => oldButtonPresses++,
          child: const Text('old focus'),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await _pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await _pump(tester);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await _pump(tester);
      expect(oldButtonPresses, 0);
    },
  );

  testWidgets('confirm pauses and focuses the existing page play button', (
    tester,
  ) async {
    final player = await _mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _pump(tester);
    expect(player.playing, isFalse);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(_focusedKey(), const ValueKey('landscape-play'));
    await tester.pump(const Duration(seconds: 5));
    expect(find.byKey(const ValueKey('landscape-play')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _pump(tester);
    expect(player.playing, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await _pump(tester);
    expect(player.position, const Duration(seconds: 30));
  });

  testWidgets(
    'paused arrows choose page controls instead of seeking or skipping',
    (tester) async {
      final selected = <int>[];
      final player = await _mount(tester, onSelect: selected.add);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _pump(tester);
      expect(_focusedKey(), const ValueKey('landscape-next'));
      expect(player.position, const Duration(seconds: 20));
      expect(player.playing, isFalse);
      expect(selected, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _pump(tester);
      expect(selected, [2]);
      expect(find.byType(BottomSheet), findsNothing);
    },
  );

  testWidgets('paused page rate control opens its existing rate picker', (
    tester,
  ) async {
    final player = await _mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _pump(tester);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _pump(tester);
    }
    expect(_focusedKey(), const ValueKey('landscape-rate'));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _pump(tester);
    expect(find.text('倍速'), findsWidgets);
    expect(player.playing, isFalse);
    expect(find.text('0.75x'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _pump(tester);
    final first = FocusManager.instance.primaryFocus;
    expect(first, isNot(isA<FocusScopeNode>()));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _pump(tester);
    expect(find.byKey(const ValueKey('player-side-panel')), findsNothing);
    expect(player.playing, isFalse);
  });

  testWidgets(
    'menu opens episodes directly and arrows choose the next episode',
    (tester) async {
      final selected = <int>[];
      await _mount(tester, onSelect: selected.add);
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await _pump(tester);
      expect(find.byType(StoryEpisodeDrawer), findsOneWidget);
      expect(_focusedButton(), const ValueKey('story-episode-1'));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _pump(tester);
      expect(_focusedButton(), const ValueKey('story-episode-2'));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _pump(tester);
      expect(selected, [2]);
      expect(find.byType(StoryEpisodeDrawer), findsNothing);
    },
  );

  testWidgets(
    'menu also opens episodes from paused controls and back stays paused',
    (tester) async {
      final player = await _mount(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await _pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      await _pump(tester);
      expect(find.byType(StoryEpisodeDrawer), findsOneWidget);
      final context = tester.element(find.byType(StoryEpisodeDrawer));
      Navigator.of(context).maybePop();
      await _pump(tester);
      expect(find.byType(VideoPlayerChrome), findsOneWidget);
      expect(find.byType(StoryEpisodeDrawer), findsNothing);
      expect(player.playing, isFalse);
    },
  );

  testWidgets('portrait pause focuses the existing play icon without a menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final player = await _mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await _pump(tester);
    final play = FocusManager.instance.primaryFocus;
    expect(play?.debugLabel, 'player play button');
    expect(find.byType(BottomSheet), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _pump(tester);
    expect(FocusManager.instance.primaryFocus, isNot(play));
    expect(player.playing, isFalse);
    expect(player.position, const Duration(seconds: 20));
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await _pump(tester);
    expect(player.playing, isTrue);
    expect(tester.takeException(), isNull);
  });
}

Key? _focusedKey() {
  Key? result;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget.key != null &&
        (widget is IconButton ||
            widget is RemoteGestureDetector ||
            widget is Semantics)) {
      result = widget.key;
      return false;
    }
    return true;
  });
  return result;
}

Key? _focusedButton() => _focusedKey();

Future<FakeNativePlayer> _mount(
  WidgetTester tester, {
  ValueChanged<int>? onSelect,
  double scale = 1,
  Widget? child,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final player = FakeNativePlayer()
    ..isPlaying = true
    ..playbackRequested = true;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(tester);
    await player.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: StreamBuilder<bool>(
        stream: player.playingStream,
        initialData: true,
        builder: (context, snapshot) => VideoPlayerChrome(
          player: player,
          title: '遥控短剧',
          shortSeries: true,
          playing: snapshot.data!,
          duration: player.duration,
          currentIndex: 1,
          episodes: List.generate(
            3,
            (i) => Chapter(itemId: '$i', title: '第 $i 集', volumeName: ''),
          ),
          onSelectEpisode: (index) async => onSelect?.call(index),
          onError: (e) => throw e,
          child: child ?? const SizedBox.expand(),
        ),
      ),
    ),
  );
  await _pump(tester);
  return player;
}

// The existing catalog has a looping playing indicator.
Future<void> _pump(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
}

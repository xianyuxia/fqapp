import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';
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

  testWidgets(
    'space toggles once per press including when a button has focus',
    (tester) async {
      final player = FakeNativePlayer()..isPlaying = true;
      final buttonFocus = FocusNode();
      var buttonPresses = 0;
      await _mountPlayer(
        tester,
        player,
        child: FilledButton(
          focusNode: buttonFocus,
          onPressed: () => buttonPresses++,
          child: const Text('按钮'),
        ),
      );
      addTearDown(buttonFocus.dispose);
      buttonFocus.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(player.isPlaying, isFalse);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.space);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(player.isPlaying, isFalse);
      expect(buttonPresses, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(player.isPlaying, isTrue);
    },
  );

  testWidgets('typing, disabled players and covered routes ignore space', (
    tester,
  ) async {
    final player = FakeNativePlayer()..isPlaying = true;
    await _mountPlayer(tester, player, child: const TextField());
    tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.isPlaying, isTrue);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpWidget(_playerApp(player, enabled: false));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(player.isPlaying, isTrue);
    await tester.pumpWidget(_playerApp(player));
    await tester.pump();
    final context = tester.element(find.byType(VideoPlayerChrome));
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('详情'))),
    );
    await tester.pumpAndSettle();
    final calls = player.calls.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(player.calls.length, calls);
  });

}

Future<void> _mountPlayer(
  WidgetTester tester,
  FakeNativePlayer player, {
  Widget? child,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await player.dispose();
  });
  await tester.pumpWidget(_playerApp(player, child: child));
  await tester.pumpAndSettle();
}

Widget _playerApp(
  FakeNativePlayer player, {
  Widget? child,
  bool enabled = true,
}) => MaterialApp(
  theme: ThemeData(splashFactory: NoSplash.splashFactory),
  home: StreamBuilder<bool>(
    stream: player.playingStream,
    initialData: player.playing,
    builder: (context, snapshot) => VideoPlayerChrome(
      player: player,
      title: '键盘测试',
      episodes: const [],
      currentIndex: 0,
      duration: player.duration,
      playing: snapshot.data!,
      enabled: enabled,
      onSelectEpisode: (_) async {},
      onError: (error) => throw error,
      child: Center(child: child ?? const SizedBox.shrink()),
    ),
  ),
);


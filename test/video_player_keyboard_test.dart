import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/widgets/video_player_chrome.dart';
import 'package:fqapp/widgets/remote_navigation.dart';
import 'package:fqapp/models/media_item.dart';
import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
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

  testWidgets(
    'left and right seek ten seconds, clamp bounds and retain pause',
    (tester) async {
      final player = FakeNativePlayer();
      final seeks = <Duration>[];
      await _mountPlayer(tester, player, onSeeked: seeks.add);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(player.position, const Duration(seconds: 30));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(player.position, const Duration(seconds: 20));
      player.currentPosition = const Duration(seconds: 3);
      player.positions.add(player.position);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(player.position, Duration.zero);
      player.currentPosition = const Duration(seconds: 117);
      player.positions.add(player.position);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(player.position, const Duration(minutes: 2));
      expect(seeks, [
        const Duration(seconds: 30),
        const Duration(seconds: 20),
        Duration.zero,
        const Duration(minutes: 2),
      ]);
      expect(player.playing, isFalse);
      expect(
        player.calls.where((call) => call == 'play' || call == 'pause'),
        isEmpty,
      );
    },
  );

  testWidgets('up and down select adjacent episodes only once per press', (
    tester,
  ) async {
    final player = FakeNativePlayer();
    final selected = <int>[];
    await _mountPlayer(
      tester,
      player,
      onSelectEpisode: (index) async => selected.add(index),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(selected, [2]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(selected, [2, 0]);
    expect(player.calls.where((call) => call.startsWith('volume:')), isEmpty);
  });

  testWidgets('episode boundaries and missing duration do not issue commands', (
    tester,
  ) async {
    final player = FakeNativePlayer(totalDuration: Duration.zero);
    final selected = <int>[];
    await _mountPlayer(
      tester,
      player,
      currentIndex: 0,
      onSelectEpisode: (i) async => selected.add(i),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pumpWidget(
      _playerApp(
        player,
        currentIndex: 2,
        onSelectEpisode: (i) async => selected.add(i),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(selected, isEmpty);
    expect(player.calls.where((call) => call.startsWith('seek:')), isEmpty);
  });

  testWidgets(
    'pending episode changes consume extra presses and recover after failure',
    (tester) async {
      final player = FakeNativePlayer();
      final change = Completer<void>();
      final selected = <int>[];
      final errors = <Object>[];
      await _mountPlayer(
        tester,
        player,
        onError: errors.add,
        onSelectEpisode: (index) {
          selected.add(index);
          return selected.length == 1 ? change.future : Future<void>.value();
        },
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(selected, [2]);
      change.completeError(StateError('episode load failed'));
      await tester.pump();
      expect(errors, hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(selected, [2, 0]);
      expect(player.calls.where((call) => call == 'play'), isEmpty);
    },
  );

  for (final key in [
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
  ]) {
    testWidgets(
      'remote confirmation ${key.keyLabel} toggles without clicking focused buttons',
      (tester) async {
        final player = FakeNativePlayer()..isPlaying = true;
        final focus = FocusNode();
        var clicked = 0;
        addTearDown(focus.dispose);
        await _mountPlayer(
          tester,
          player,
          child: TextButton(
            focusNode: focus,
            onPressed: () => clicked++,
            child: const Text('button'),
          ),
        );
        focus.requestFocus();
        await tester.pump();
        await tester.sendKeyDownEvent(key);
        await tester.pump();
        await tester.sendKeyRepeatEvent(key);
        await tester.sendKeyUpEvent(key);
        await tester.pump();
        expect(player.playing, isFalse);
        expect(player.calls.where((call) => call == 'pause'), hasLength(1));
        expect(clicked, 0);
      },
    );
  }

  testWidgets(
    'direction and confirmation keys yield to text entry and overlays',
    (tester) async {
      final player = FakeNativePlayer();
      final selected = <int>[];
      await _mountPlayer(
        tester,
        player,
        child: const TextField(),
        onSelectEpisode: (i) async => selected.add(i),
      );
      final focus = tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode;
      for (final key in _allKeys) {
        focus.requestFocus();
        await tester.pump();
        final calls = player.calls.length;
        await tester.sendKeyEvent(key);
        await tester.pump();
        expect(player.calls.length, calls);
      }
      focus.unfocus();
      await tester.pumpWidget(
        _playerApp(
          player,
          blocked: true,
          onSelectEpisode: (i) async => selected.add(i),
        ),
      );
      await tester.pump();
      final calls = player.calls.length;
      for (final key in _allKeys) {
        await tester.sendKeyEvent(key);
      }
      expect(player.calls.length, calls);
      expect(selected, isEmpty);
    },
  );

  testWidgets(
    'modifier shortcuts and background routes do not control playback',
    (tester) async {
      final player = FakeNativePlayer();
      final selected = <int>[];
      await _mountPlayer(
        tester,
        player,
        onSelectEpisode: (i) async => selected.add(i),
      );
      final calls = player.calls.length;
      for (final modifier in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.metaLeft,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        for (final key in _allKeys) {
          await tester.sendKeyEvent(key);
        }
        await tester.sendKeyUpEvent(modifier);
      }
      expect(player.calls.length, calls);
      final context = tester.element(find.byType(VideoPlayerChrome));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('covered')),
        ),
      );
      await tester.pumpAndSettle();
      final coveredCalls = player.calls.length;
      for (final key in _allKeys) {
        await tester.sendKeyEvent(key);
      }
      expect(coveredCalls, greaterThanOrEqualTo(calls));
      expect(player.calls.length, coveredCalls);
      expect(selected, isEmpty);
    },
  );

  testWidgets('disabled and background players ignore every playback key', (
    tester,
  ) async {
    final player = FakeNativePlayer();
    final selected = <int>[];
    await _mountPlayer(
      tester,
      player,
      onSelectEpisode: (i) async => selected.add(i),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    var calls = player.calls.length;
    for (final key in _allKeys) {
      await tester.sendKeyEvent(key);
    }
    expect(player.calls.length, calls);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      _playerApp(
        player,
        enabled: false,
        onSelectEpisode: (i) async => selected.add(i),
      ),
    );
    await tester.pump();
    calls = player.calls.length;
    for (final key in _allKeys) {
      await tester.sendKeyEvent(key);
    }
    expect(player.calls.length, calls);
    expect(selected, isEmpty);
  });

  testWidgets('player yields to the app dock focus', (tester) async {
    final player = FakeNativePlayer()..isPlaying = true;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var activations = 0;
    await _mountPlayer(
      tester,
      player,
      child: RemoteNavigationRegion(
        child: Row(
          children: [
            TextButton(
              focusNode: focus,
              onPressed: () {},
              child: const Text('首页'),
            ),
            TextButton(onPressed: () => activations++, child: const Text('书架')),
          ],
        ),
      ),
    );
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(activations, 1);
    expect(player.playing, isTrue);
    expect(player.position, const Duration(seconds: 20));
  });

  testWidgets('Windows retains its existing volume and playback keys', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final player = FakeNativePlayer()
        ..isPlaying = true
        ..playbackRequested = true;
      final selected = <int>[];
      await _mountPlayer(
        tester,
        player,
        onSelectEpisode: (i) async => selected.add(i),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(player.volume, closeTo(.05, .001));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(player.volume, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(player.position, const Duration(seconds: 30));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(player.playing, isFalse);
      expect(selected, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<void> _mountPlayer(
  WidgetTester tester,
  FakeNativePlayer player, {
  Widget? child,
  int currentIndex = 1,
  Future<void> Function(int)? onSelectEpisode,
  ValueChanged<Duration>? onSeeked,
  ValueChanged<Object>? onError,
}) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await player.dispose();
  });
  await tester.pumpWidget(
    _playerApp(
      player,
      child: child,
      currentIndex: currentIndex,
      onSelectEpisode: onSelectEpisode,
      onSeeked: onSeeked,
      onError: onError,
    ),
  );
  await tester.pumpAndSettle();
}

Widget _playerApp(
  FakeNativePlayer player, {
  Widget? child,
  int currentIndex = 1,
  Future<void> Function(int)? onSelectEpisode,
  ValueChanged<Duration>? onSeeked,
  ValueChanged<Object>? onError,
  bool enabled = true,
  bool blocked = false,
}) => MaterialApp(
  theme: ThemeData(splashFactory: NoSplash.splashFactory),
  home: StreamBuilder<bool>(
    stream: player.playingStream,
    initialData: player.playing,
    builder: (context, snapshot) => VideoPlayerChrome(
      player: player,
      title: '键盘测试',
      episodes: List.generate(
        3,
        (i) => Chapter(itemId: '$i', title: '第 $i 集', volumeName: ''),
      ),
      currentIndex: currentIndex,
      duration: player.duration,
      playing: snapshot.data!,
      enabled: enabled,
      interactionBlocked: blocked,
      onSeeked: onSeeked,
      onSelectEpisode: onSelectEpisode ?? (_) async {},
      onError: onError ?? (error) => throw error,
      child: Center(child: child ?? const SizedBox.shrink()),
    ),
  ),
);

const _allKeys = [
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
];

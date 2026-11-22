import 'package:flutter/widgets.dart';

const isMediaDesktop = false;
const isWindowsDesktop = false;

bool playbackAppIsActive(AppLifecycleState? state) =>
    state == null || state == AppLifecycleState.resumed;

bool desktopInactiveStillVisible(AppLifecycleState state) =>
    state == AppLifecycleState.resumed;

class DesktopSystemSession extends ChangeNotifier {
  static final instance = DesktopSystemSession();
  bool get suspended => false;
  AppLifecycleState get lifecycle =>
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
  void accept(dynamic event) {}
}

class DesktopPlatform {
  static final instance = DesktopPlatform();
  static final navigatorKey = GlobalKey<NavigatorState>();
  static final readerBrightness = ValueNotifier<double>(1);
  static final fullscreen = ValueNotifier<bool>(false);

  Future<void> Function()? beforeClose;
  Future<void> initialize() async {}
  Future<void> disposeMedia() async {}
  Future<void> setFullscreen(bool value) async {}
  Future<Map<String, dynamic>?> pickBook() async => null;
  Stream<dynamic> events(String name) => const Stream.empty();

  Future<dynamic> invoke(
    String channel,
    String method,
    dynamic arguments,
  ) async => throw UnsupportedError('此桌面通道在浏览器不可用');

  Widget videoSurface(int id, {Key? key}) => const SizedBox.shrink();
}

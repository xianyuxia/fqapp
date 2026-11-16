import 'dart:async';

import 'package:flutter/services.dart';

import 'platform_channel.dart';

/// Physical D-pad/keyboard availability, including devices attached after launch.
class RemoteInputDevices {
  StreamSubscription<dynamic>? _events;
  bool _disposed = false;

  Future<void> watch(void Function(bool) onChanged) async {
    try {
      final connected = await const AppMethodChannel(
        'fqapp/remote_input',
      ).invokeMethod<bool>('isConnected');
      if (_disposed || connected == null) return;
      onChanged(connected);
      _events = const AppEventChannel('fqapp/remote_input/events')
          .receiveBroadcastStream()
          .listen((value) {
            if (!_disposed && value is bool) onChanged(value);
          }, onError: (Object _) {});
    } on MissingPluginException {
      // Host tests and non-Android builds have no Android input manager.
    } on PlatformException {
      // Navigation keys remain usable if device discovery is unavailable.
    }
  }

  void dispose() {
    _disposed = true;
    unawaited(_events?.cancel());
  }
}

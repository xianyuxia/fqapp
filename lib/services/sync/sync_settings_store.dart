import 'package:flutter/foundation.dart';

abstract interface class SyncSettingsStore implements Listenable {
  Map<String, String> get config;
  Map<String, String> configFor(String provider);
  bool get enabled;
  bool get busy;
  String get status;
  DateTime? get lastSuccess;
  Future<void> configure(Map<String, String> config);
  Future<void> setAutoSync(bool enabled);
  Future<void> sync();
}

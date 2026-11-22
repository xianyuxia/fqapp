import 'package:flutter/widgets.dart';

const browserMediaAvailable = false;
void installBrowserMedia() {}
Widget browserVideo(int id) => throw UnsupportedError('Web player on native');
Future<bool> openBrowserVideoFullscreen(int? id) async => false;

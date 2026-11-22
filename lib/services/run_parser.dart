import 'dart:isolate';

import 'package:flutter/foundation.dart';

Future<T> runParser<T>(T Function() parse) async =>
    kIsWeb ? parse() : Isolate.run(parse);

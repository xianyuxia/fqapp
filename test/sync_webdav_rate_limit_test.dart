import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/sync/sync_transport.dart';

void main() {
  for (final method in ['MKCOL', 'PROPFIND', 'GET', 'PUT']) {
    test('$method reports HTTP 429 with server cooldown', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final subscription = server.listen((request) async {
        requests++;
        expect(request.method, method);
        await request.drain<void>();
        request.response.statusCode = 429;
        request.response.headers.set('Retry-After', '180');
        await request.response.close();
      });
      final transport = WebDavSyncTransport(
        'http://127.0.0.1:${server.port}/sync/',
        'user',
        'pass',
      );
      try {
        const name = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.a.json';
        final operation = switch (method) {
          'MKCOL' => transport.prepare(),
          'PROPFIND' => transport.list(),
          'GET' => transport.read(name),
          _ => transport.write(name, Uint8List.fromList([1, 2])),
        };
        await expectLater(
          operation,
          throwsA(
            isA<SyncRateLimitFailure>()
                .having(
                  (e) => e.retryAfter,
                  'cooldown',
                  const Duration(seconds: 180),
                )
                .having((e) => e.message, 'message', contains('HTTP 429')),
          ),
        );
        expect(
          requests,
          1,
          reason: 'do not immediately retry a throttled request',
        );
      } finally {
        transport.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    });
  }

  for (final (hint, futureDate) in <(String?, bool)>[
    (null, false),
    ('invalid', false),
    ('-1', false),
    ('0', false),
    (HttpDate.format(DateTime.now().subtract(const Duration(days: 1))), false),
    (HttpDate.format(DateTime.now().add(const Duration(minutes: 5))), true),
  ]) {
    test('Retry-After $hint uses a safe cooldown', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = 429;
        if (hint != null) request.response.headers.set('Retry-After', hint);
        await request.response.close();
      });
      final transport = WebDavSyncTransport(
        'http://127.0.0.1:${server.port}/sync/',
        'user',
        'pass',
      );
      try {
        // Date hints lose subsecond precision on the wire.
        await expectLater(
          transport.list(),
          throwsA(
            isA<SyncRateLimitFailure>().having(
              (e) => e.retryAfter.inSeconds,
              'cooldown seconds',
              futureDate ? inInclusiveRange(280, 300) : equals(60),
            ),
          ),
        );
      } finally {
        transport.close();
        await subscription.cancel();
        await server.close(force: true);
      }
    });
  }
}

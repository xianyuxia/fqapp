import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/sync/multi_device_sync_service.dart';
import 'package:fqapp/services/sync/sync_document.dart';
import 'package:fqapp/services/sync/sync_transport.dart';

// Opt-in integration test. Secrets are provided only through the process
// environment; this file and test output never contain credentials.
void main() {
  final env = Platform.environment;
  test(
    'live WebDAV fixed-slot overwrites, concurrent devices and deletion merge',
    () async {
      HttpOverrides.global = null;
      final a = newSyncIdentity(), b = newSyncIdentity();
      final folder = 'fqappx-validation-${newSyncIdentity().substring(0, 8)}';
      final transport = WebDavSyncTransport(
        '${env['FQAPPX_DAV_TEST_ROOT']}$folder/',
        env['FQAPPX_DAV_TEST_USER']!,
        env['FQAPPX_DAV_TEST_PASSWORD']!,
      );
      final exchange = SyncExchange(transport),
          first = SyncDocument(),
          second = SyncDocument();
      final ownFiles = <String>{};
      Future<void> publish(String actor, int sequence, SyncDocument doc) async {
        final slot = SyncSlot(actor, sequence, doc.copy());
        ownFiles.add(slot.filename);
        await exchange.publish(slot);
      }

      try {
        await transport.prepare();
        first.change('test-one', {'n': 1}, actor: a, wall: 1);
        second.change('test-two', {'n': 2}, actor: b, wall: 2);
        await publish(a, 1, first);
        await publish(b, 1, second);
        for (final slot in (await exchange.readAll()).values) {
          first.merge(slot.document);
          second.merge(slot.document);
        }
        second.change('test-one', null, actor: b, wall: 3);
        await publish(
          b,
          2,
          second,
        ); // Other slot, leaves B's previous slot valid.
        for (final slot in (await exchange.readAll()).values) {
          first.merge(slot.document);
        }
        expect(first.visible.containsKey('test-one'), false);
        first.change('test-three', {'n': 3}, actor: a, wall: 4);
        await publish(a, 2, first);
        first.change('test-three', {'n': 4}, actor: a, wall: 5);
        await publish(
          a,
          3,
          first,
        ); // Overwrite and read-back verification, not just create.
        final all = await exchange.readAll();
        expect(all[a]!.sequence, 3);
        expect(all[b]!.sequence, 2);
        final finalDoc = SyncDocument();
        for (final slot in all.values) {
          finalDoc.merge(slot.document);
        }
        expect(finalDoc.visible.containsKey('test-one'), false);
        expect(finalDoc.visible['test-three']!['n'], 4);
        expect((await transport.list()).length, 4);
      } finally {
        // Only delete exact files this test created. Some providers forbid deleting
        // even an empty folder, so the isolated validation folder may remain.
        for (final name in ownFiles) {
          await transport.request('DELETE', transport.root.resolve(name));
        }
        transport.close();
      }
    },
    skip: env['FQAPPX_DAV_TEST_PASSWORD'] == null,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

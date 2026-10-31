import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/sync/multi_device_sync_service.dart';
import 'package:fqapp/services/sync/sync_document.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real service and HTTP WebDAV merge remote deletes, re-adds, and in-flight local changes',
    () async {
      HttpOverrides.global = null;
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'fqappx-service-test-',
      );
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      final files = <String, Uint8List>{};
      var puts = 0;
      Completer<void>? held, release;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        if (request.headers.value('Authorization') != 'Basic dXNlcjpwYXNz') {
          request.response.statusCode = 401;
          await request.response.close();
          return;
        }
        final name = request.uri.pathSegments.last;
        switch (request.method) {
          case 'MKCOL':
            request.response.statusCode = 405;
          case 'PROPFIND':
            if (held != null && !held.isCompleted) {
              held.complete();
              await release!.future;
            }
            request.response.statusCode = 207;
            request.response.write(
              '<d:multistatus xmlns:d="DAV:">${files.keys.map((n) => '<d:response><d:href>/sync/$n</d:href></d:response>').join()}</d:multistatus>',
            );
          case 'GET':
            final data = files[name];
            if (data == null) {
              request.response.statusCode = 404;
            } else {
              request.response.add(data);
            }
          case 'PUT':
            final buffer = BytesBuilder();
            await for (final chunk in request) {
              buffer.add(chunk);
            }
            files[name] = buffer.takeBytes();
            puts++;
            request.response.statusCode = 201;
          default:
            request.response.statusCode = 405;
        }
        await request.response.close();
      });
      final service = MultiDeviceSyncService.instance;
      try {
        await service.initialize();
        expect(service.ready, true);
        final shelf = ShelfStore.instance;
        MediaItem item(String id) => MediaItem(
          id: id,
          title: 'Test $id',
          kind: 'book',
          cover: '',
          author: '',
          badge: '',
          ep: '',
        );
        await shelf.add(item('one'));
        await service.configure({
          'provider': 'webdav',
          'endpoint': 'http://127.0.0.1:${server.port}/sync/',
          'username': 'user',
          'password': 'pass',
          'enabled': 'true',
        });
        await service.sync();
        expect(service.status, '同步完成');
        expect(puts, 1);
        final own = files.keys.single;
        final remote = SyncSlot.decode(files[own]!, own).document.copy();
        const actor = 'dddddddddddddddddddddddddddddddd';
        remote.change(
          's|book|one',
          null,
          actor: actor,
          wall: DateTime.now().millisecondsSinceEpoch,
        );
        final deletion = SyncSlot(actor, 1, remote);
        files[deletion.filename] = deletion.encode();
        await service.sync();
        expect(service.status, '同步完成');
        expect(shelf.contains('book', 'one'), false);
        final before = puts;
        await service.sync();
        await service.sync();
        expect(
          puts,
          before,
          reason: 'unchanged sync does not rewrite or advance active slot',
        );
        expect(shelf.contains('book', 'one'), false);
        expect(
          service.hasScheduledSync,
          false,
          reason:
              'applying unchanged remote values must not create an endless automatic-sync loop',
        );
        // Change the shelf while the HTTP read is in progress.
        held = Completer();
        release = Completer();
        final syncing = service.sync();
        await held.future;
        await shelf.add(item('two'));
        release.complete();
        await syncing;
        expect(shelf.contains('book', 'two'), true);
        await shelf.add(item('one'));
        await service.sync();
        expect(shelf.contains('book', 'one'), true);
        final snapshots = [
          for (final e in files.entries) SyncSlot.decode(e.value, e.key),
        ]..sort((a, b) => b.sequence.compareTo(a.sequence));
        final merged = SyncDocument();
        for (final s in snapshots) {
          merged.merge(s.document);
        }
        expect(merged.visible.keys, containsAll(['s|book|one', 's|book|two']));
        expect(files.length, lessThanOrEqualTo(4));
        // Saving a settings draft waits for an in-flight sync. A token rotated
        // during that wait must survive the stale draft from the open form.
        held = Completer();
        release = Completer();
        final pendingSync = service.sync();
        await held.future;
        final draft = {...service.config, 'enabled': 'false'};
        final pendingSave = service.configure(draft);
        await service.saveProviderCredentials('webdav', {
          'password': 'rotated-during-settings-save',
        });
        release.complete();
        await pendingSync;
        await pendingSave;
        expect(service.config['password'], 'rotated-during-settings-save');
        final activeBefore = Map<String, String>.from(service.config);
        await service.rememberProvider({
          'provider': 'quark',
          'endpoint': 'fqappx-sync-v1',
          'password': 'unit-test-only-token',
          'enabled': 'false',
        });
        expect(
          service.config,
          activeBefore,
          reason: 'remembering another login must not switch or enable sync',
        );
        expect(service.configFor('quark')['password'], 'unit-test-only-token');
        await service.saveProviderCredentials('quark', {
          'password': 'rotated-unit-test-token',
        });
        expect(
          service.configFor('quark')['password'],
          'rotated-unit-test-token',
        );
        expect(service.config, activeBefore);
        expect(
          service.configFor('webdav')['endpoint'],
          activeBefore['endpoint'],
        );
        final oldProfile = service.configFor('quark')['profile'];
        await service.rememberProvider({
          'provider': 'quark',
          'endpoint': 'fqappx-sync-v1',
          'password': 'new-account-unit-test-token',
          'enabled': 'false',
        });
        await service.saveProviderCredentials('quark', {
          'password': 'stale-old-account-refresh',
        }, profile: oldProfile);
        expect(
          service.configFor('quark')['password'],
          'new-account-unit-test-token',
          reason:
              'late token refresh cannot overwrite a newly authorized account',
        );
        expect(jsonEncode(merged.toJson()).contains('password'), false);
      } finally {
        await service.shutdown();
        await subscription.cancel();
        await server.close(force: true);
        await Hive.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

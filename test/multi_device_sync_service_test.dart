import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/webdav_sync_document.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/secure_key_provider.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/sync/multi_device_sync_service.dart';
import 'package:fqapp/services/sync/sync_transport.dart';
import 'package:fqapp/services/sync/upstream_webdav_exchange.dart';
import 'package:fqapp/services/webdav_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real service and upstream WebDAV merge remote deletes, re-adds, and in-flight local changes',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final keyChannel = const MethodChannel('fqapp/secure_keys');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final keys = InMemorySecureKeyStorage();
      SecureKeyProvider.instance.resetForTest();
      messenger.setMockMethodCallHandler(keyChannel, (call) async {
        final args = call.arguments as Map;
        final key = args['key'] as String;
        switch (call.method) {
          case 'read':
            return keys.read(key);
          case 'write':
            await keys.write(key, args['value'] as String);
          case 'delete':
            await keys.delete(key);
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(keyChannel, null);
        SecureKeyProvider.instance.resetForTest();
      });
      SharedPreferences.setMockInitialValues({});
      final directory = await Directory.systemTemp.createTemp(
        'fqappx-service-test-',
      );
      Hive.init(directory.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
      const publicName = 'fqapp-sync.json';
      final files = <String, Uint8List>{};
      final tags = <String, String>{};
      var puts = 0, revision = 0;
      Completer<void>? held, release;
      final polls = <({Timer timer, void Function(Timer) tick})>[];
      final observePolling = ZoneSpecification(
        createPeriodicTimer: (_, parent, zone, interval, tick) {
          final timer = parent.createPeriodicTimer(zone, interval, tick);
          expect(interval, const Duration(minutes: 2));
          polls.add((timer: timer, tick: tick));
          return timer;
        },
      );
      void replace(String name, Uint8List bytes) {
        files[name] = bytes;
        tags[name] = '"${++revision}"';
      }

      Future<http.Response> respond(http.Request request) async {
        expect(request.headers['Authorization'], 'Basic dXNlcjpwYXNz');
        final name = request.url.pathSegments.last;
        if (request.method == 'GET') {
          if (name == publicName && held != null && !held.isCompleted) {
            held.complete();
            await release!.future;
          }
          final data = files[name];
          return data == null
              ? http.Response('', 404)
              : http.Response.bytes(data, 200, headers: {'etag': tags[name]!});
        }
        expect(request.method, 'PUT');
        final expected = tags[name];
        final matches = expected == null
            ? request.headers['if-none-match'] == '*'
            : request.headers['if-match'] == expected;
        if (!matches) return http.Response('', 412);
        puts++;
        replace(name, request.bodyBytes);
        return http.Response('', 201);
      }

      final service = MultiDeviceSyncService.forTest(
        (config) => UpstreamWebDavExchange(
          WebDavClient(config, client: MockClient(respond)),
          WebDavClient(
            config,
            client: MockClient(respond),
            forSyncMetadata: true,
          ),
        ),
      );
      try {
        final target = {
          'provider': 'webdav',
          'endpoint': 'https://dav.example.test/sync/',
          'username': 'user',
          'password': 'pass',
          'enabled': 'true',
        };
        FlutterSecureStorage.setMockInitialValues({
          'fqapp.multi-device-sync.config.v1': jsonEncode(target),
          'fqapp.multi-device-sync.providers.v1': jsonEncode({
            'quark': {
              'provider': 'quark',
              'endpoint': 'fqappx-sync-v1',
              'password': 'unit-test-only-token',
              'enabled': 'false',
              'profile': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            },
          }),
        });
        await keys.write(
          'fqapp.webdav.config.v1',
          jsonEncode({
            'directory': 'https://previous.example.test/',
            'username': 'legacy-reader',
            'password': 'legacy-password',
            'enabled': true,
          }),
        );
        final binding = TestWidgetsFlutterBinding.instance;
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await service.initialize();
        expect(service.ready, true);
        expect(service.needsWebDavReview, true);
        expect(service.enabled, false);
        await expectLater(
          service.setAutoSync(true),
          throwsA(isA<SyncFailure>()),
        );
        expect(service.enabled, false);
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
        final preview = await service.previewWebDav(target);
        expect(preview.localShelf, 1);
        expect(preview.cloudShelf, 0);
        expect(puts, 0);
        await runZoned(
          () =>
              service.configure({...target, 'webdavPreview': preview.revision}),
          zoneSpecification: observePolling,
        );
        expect(service.needsWebDavReview, false);
        await service.sync();
        expect(polls.single.timer.isActive, true);
        expect(service.status, '同步完成');
        expect(puts, 3);
        final official = WebDavSyncDocument.decode(files[publicName]!);
        expect(official.backup.shelf.single.item.id, 'one');
        replace(
          publicName,
          WebDavSyncDocument(
            LibraryBackup.capture(
              shelf: [],
              history: [],
              watched: {},
              createdAt: official.backup.createdAt,
            ),
            {
              ShelfStore.keyOf(item('one')):
                  DateTime.now().millisecondsSinceEpoch,
            },
          ).encode(),
        );
        await service.sync();
        expect(service.status, '同步完成');
        expect(shelf.contains('book', 'one'), false);
        final before = puts;
        await service.sync();
        await service.sync();
        expect(
          puts,
          before,
          reason: 'unchanged sync does not rewrite the public file or journal',
        );
        expect(shelf.contains('book', 'one'), false);
        expect(
          service.hasScheduledSync,
          false,
          reason:
              'applying unchanged remote values must not create an endless automatic-sync loop',
        );
        polls.single.tick(polls.single.timer);
        expect(
          service.busy,
          true,
          reason: 'a poll checks remote without local edits',
        );
        await service.sync();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(polls.single.timer.isActive, false);
        expect(
          service.busy,
          true,
          reason: 'pausing starts WebDAV sync immediately',
        );
        await service.sync();
        runZoned(
          () =>
              binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
          zoneSpecification: observePolling,
        );
        expect(polls, hasLength(2));
        expect(polls.last.timer.isActive, true);
        await service.sync();
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
        final merged = WebDavSyncDocument.decode(files[publicName]!);
        expect(merged.backup.shelf.map((row) => row.item.id), ['one', 'two']);
        expect(
          files.keys,
          unorderedEquals([publicName, WebDavClient.metadataName]),
        );
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
        expect(polls.last.timer.isActive, false);
        expect(service.config['password'], 'rotated-during-settings-save');
        final activeBefore = Map<String, String>.from(service.config);
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
        await service.saveProviderCredentials('quark', {
          'password': 'stale-old-account-refresh',
        }, profile: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
        expect(
          service.configFor('quark')['password'],
          'rotated-unit-test-token',
          reason: 'late token refresh cannot overwrite a different profile',
        );
        expect(utf8.decode(files[publicName]!).contains('password'), false);
      } finally {
        await service.shutdown();
        await Hive.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

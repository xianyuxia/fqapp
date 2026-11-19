import 'dart:convert';
import 'dart:typed_data';

import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/models/webdav_sync_document.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/sync/sync_document.dart';
import 'package:fqapp/services/sync/sync_snapshot.dart';
import 'package:fqapp/services/sync/sync_transport.dart';
import 'package:fqapp/services/sync/upstream_webdav_exchange.dart';
import 'package:fqapp/services/webdav_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const phone = '11111111111111111111111111111111';
const tablet = '22222222222222222222222222222222';
const publicName = 'fqapp-sync.json';
const metadataName = 'fqapp-webdav-state.json';
const config = WebDavConfig(
  directory: 'https://dav.example.test/library/',
  username: '',
  password: '',
  enabled: true,
);

LibraryBackup backup({
  List<Map<String, dynamic>> history = const [],
  List<ShelfRecord> shelf = const [],
  String? ai,
}) => LibraryBackup.capture(
  shelf: shelf,
  history: history,
  watched: {},
  aiData: ai,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1),
);

Map<String, dynamic> progress(
  String id,
  int chapter,
  int time, {
  String? source,
}) => {
  'id': id,
  'kind': 'book',
  'title': id,
  'episode': chapter,
  'time': time,
  'source': ?source,
};

SyncDocument changes(String actor, List<Map<String, dynamic>> items) {
  final document = SyncDocument();
  final records = SyncSnapshot.fromBackup(backup(history: items)).values;
  for (final entry in records.entries) {
    document.change(
      entry.key,
      entry.value,
      actor: actor,
      wall: entry.value['time'] as int,
    );
  }
  return document;
}

class _Dav {
  final files = <String, ({Uint8List bytes, String tag})>{};
  int _next = 0;
  int puts = 0;
  void Function()? beforePublicWrite;
  bool failPublicWrite = false;

  void put(String name, Uint8List bytes) {
    files[name] = (bytes: bytes, tag: '"${++_next}"');
  }

  WebDavSyncDocument get result =>
      WebDavSyncDocument.decode(files[publicName]!.bytes);

  Future<http.Response> respond(http.Request request) async {
    final name = request.url.pathSegments.last;
    expect([publicName, metadataName], contains(name));
    if (request.method == 'PUT' && name == publicName) {
      if (failPublicWrite) throw http.ClientException('network unavailable');
      final action = beforePublicWrite;
      beforePublicWrite = null;
      action?.call();
    }
    final current = files[name];
    if (request.method == 'GET') {
      return current == null
          ? http.Response('', 404)
          : http.Response.bytes(
              current.bytes,
              200,
              headers: {'etag': current.tag},
            );
    }
    expect(request.method, 'PUT');
    puts++;
    if (current == null
        ? request.headers['if-none-match'] != '*'
        : request.headers['if-match'] != current.tag) {
      return http.Response('', 412);
    }
    put(name, request.bodyBytes);
    return http.Response('', 204);
  }

  UpstreamWebDavExchange connect({SyncTransport? legacyTransport}) {
    final exchange = UpstreamWebDavExchange(
      WebDavClient(config, client: MockClient(respond)),
      WebDavClient(config, client: MockClient(respond), forSyncMetadata: true),
      legacyTransport: legacyTransport,
    );
    addTearDown(exchange.close);
    return exchange;
  }
}

class _LegacySlots implements SyncTransport {
  final slots = <String, Uint8List>{};
  int reads = 0;

  void put(SyncSlot slot) => slots[slot.filename] = slot.encode();

  @override
  Future<List<String>> list() async => slots.keys.toList();

  @override
  Future<Uint8List?> read(String name) async {
    reads++;
    return slots[name];
  }

  @override
  Future<void> prepare() async => fail('Migration must not create folders');

  @override
  Future<void> write(String name, Uint8List bytes) async =>
      fail('Migration must never write old snapshots');

  @override
  void close() {}
}

void main() {
  test(
    'old WebDAV snapshots migrate once and keep their original bytes',
    () async {
      final server = _Dav()
        ..put(
          publicName,
          WebDavSyncDocument(
            backup(history: [progress('shared', 80, 110)]),
          ).encode(),
        )
        ..put(
          metadataName,
          Uint8List.fromList(
            utf8.encode(
              syncJson({
                'format': 'fqapp.webdav-state',
                'version': 1,
                'committed': changes(tablet, [
                  progress('shared', 80, 110),
                ]).toJson(),
              }),
            ),
          ),
        );
      final old = _LegacySlots();
      final previous = SyncSlot(
        phone,
        1,
        changes(phone, [
          progress('legacy-only', 5, 90),
          progress('shared', 100, 100),
        ]),
      );
      old.put(previous);
      final original = old.slots[previous.filename]!;
      final exchange = server.connect(legacyTransport: old);
      final preview = await exchange.preview(
        SyncDocument(),
        requireJournal: true,
      );
      expect(preview.remote!.history.map((row) => row['id']), [
        'legacy-only',
        'shared',
      ]);
      expect(server.puts, 0);

      await exchange.sync(SyncDocument(), requireJournal: true);
      final history = server.result.backup.history;
      expect(
        history.singleWhere((row) => row['id'] == 'legacy-only')['episode'],
        5,
      );
      expect(
        history.singleWhere((row) => row['id'] == 'shared')['episode'],
        80,
      );
      expect(old.slots[previous.filename], orderedEquals(original));
      expect(old.slots, hasLength(1));

      final reads = old.reads;
      old.put(
        SyncSlot(tablet, 2, changes(tablet, [progress('stale', 999, 200)])),
      );
      await exchange.sync(SyncDocument());
      expect(old.reads, reads);
      expect(server.result.backup.history.map((row) => row['id']), [
        'legacy-only',
        'shared',
      ]);
    },
  );

  test(
    'two compatible writers can publish concurrently without losing either record',
    () async {
      final server = _Dav();
      final first = server.connect();
      final second = server.connect();

      await Future.wait([
        first.sync(changes(phone, [progress('one', 10, 20)])),
        second.sync(changes(tablet, [progress('two', 12, 30)])),
      ]);
      expect(server.result.backup.history.map((row) => row['id']), [
        'one',
        'two',
      ]);
    },
  );

  test(
    'preview is read-only, and later concurrent progress reaches upstream clients',
    () async {
      final server = _Dav()
        ..put(
          publicName,
          WebDavSyncDocument(
            backup(
              history: [progress('123', 4, 10, source: 'shuqi')],
              ai: 'YWk=',
            ),
          ).encode(),
        );
      final first = server.connect();
      final second = server.connect();
      final phoneState = changes(phone, [progress('book', 100, 100)]);
      final tabletState = changes(tablet, [progress('book', 80, 110)]);
      final preview = await first.preview(phoneState);
      expect(preview.remote!.history.single['source'], 'shuqi');
      expect(server.puts, 0);

      await first.sync(phoneState);
      final merged = await second.sync(tabletState);
      final official = server.result.backup;
      expect(
        official.history.singleWhere((row) => row['id'] == 'book')['episode'],
        80,
      );
      expect(
        official.history.singleWhere((row) => row['id'] == '123')['episode'],
        4,
      );
      expect(official.aiData, 'YWk=');
      expect(merged.records['h|book|book'], hasLength(2));
      final writes = server.puts;
      await second.sync(merged);
      expect(server.puts, writes);

      // After observing both versions, intentionally rereading wins even when
      // this device's timestamp is earlier.
      final reread = SyncSnapshot.fromBackup(
        backup(history: [progress('book', 20, 90)]),
      );
      merged.change(
        'h|book|book',
        reread.values['h|book|book'],
        actor: tablet,
        wall: 90,
      );
      await second.sync(merged);
      expect(
        server.result.backup.history.singleWhere(
          (row) => row['id'] == 'book',
        )['episode'],
        20,
      );
    },
  );

  test(
    'a conditional-write conflict imports the newer upstream deletion before retrying',
    () async {
      final server = _Dav();
      final exchange = server.connect();
      final original = changes(phone, [progress('to-delete', 2, 10)]);
      final originalMerged = await exchange.sync(original);
      final alternate = changes(tablet, [progress('new', 3, 20)]);
      server.beforePublicWrite = () {
        server.put(publicName, WebDavSyncDocument(backup()).encode());
      };
      await exchange.sync(alternate);
      expect(server.result.backup.history.map((row) => row['id']), ['new']);
      await exchange.sync(originalMerged);
      expect(server.result.backup.history.map((row) => row['id']), ['new']);
    },
  );

  test(
    'a pending publication can be resumed and a missing known journal is rejected',
    () async {
      final server = _Dav()..failPublicWrite = true;
      final first = server.connect();
      final local = changes(phone, [progress('book', 12, 10)]);
      await expectLater(first.sync(local), throwsA(isA<WebDavException>()));
      expect(server.files[metadataName], isNotNull);
      expect(server.files[publicName], isNull);

      server.failPublicWrite = false;
      final second = server.connect();
      await second.sync(SyncDocument());
      expect(server.result.backup.history.single['episode'], 12);

      server.files.remove(metadataName);
      await expectLater(
        second.sync(local, requireJournal: true),
        throwsA(isA<SyncFailure>()),
      );
      expect(server.result.backup.history.single['episode'], 12);
    },
  );

  test('upstream shelf removals win over an offline favourite', () async {
    final item = MediaItem(
      id: 'one',
      kind: 'book',
      title: 'one',
      cover: '',
      author: '',
      badge: '',
      ep: '',
    );
    final shelf = ShelfRecord(
      item: item,
      addedAt: DateTime.fromMillisecondsSinceEpoch(10),
    );
    final server = _Dav()
      ..put(
        publicName,
        WebDavSyncDocument(backup(), {ShelfStore.keyOf(item): 100}).encode(),
      );
    final snapshot = SyncSnapshot.fromBackup(backup(shelf: [shelf]));
    final local = SyncDocument()
      ..change(
        's|book|one',
        snapshot.values['s|book|one'],
        actor: phone,
        wall: 110,
      );
    await server.connect().sync(local);
    expect(server.result.backup.shelf, isEmpty);
    expect(server.result.removedShelf[ShelfStore.keyOf(item)], 100);
  });
}

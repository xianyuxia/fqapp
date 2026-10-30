import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/library_store.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/sync/sync_document.dart';
import 'package:fqapp/services/sync/sync_snapshot.dart';
import 'package:fqapp/services/sync/sync_transport.dart';
import 'package:fqapp/services/sync/weiyun_hash.dart';
import 'package:fqapp/services/sync/cloud_sync_transport.dart';

const a = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const b = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const c = 'cccccccccccccccccccccccccccccccc';
SyncDocument combine(SyncDocument x, SyncDocument y) => x.copy()..merge(y);
Map<String, dynamic> book(String id) => {
  'id': id,
  'kind': 'book',
  'title': 'Test $id',
  'cover': '',
  'author': '',
  'badge': '',
  'ep': '',
  'seriesId': null,
  'episodeId': null,
  'addedAt': 100,
};
MediaItem item(String id) => MediaItem(
  id: id,
  kind: 'book',
  title: 'Test $id',
  cover: '',
  author: '',
  badge: '',
  ep: '',
);

class MemoryStorage implements SyncTransport {
  final files = <String, Uint8List>{};
  bool corrupt = false;
  @override
  Future<void> prepare() async {}
  @override
  Future<List<String>> list() async => files.keys.toList();
  @override
  Future<Uint8List?> read(String name) async => files[name];
  @override
  Future<void> write(String name, Uint8List bytes) async {
    files[name] = corrupt
        ? Uint8List.fromList(bytes.sublist(0, bytes.length ~/ 2))
        : bytes;
  }

  @override
  void close() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'stale offline adds cannot revive a deletion; explicit later re-add can',
    () {
      final initial = SyncDocument()
        ..change('s|book|one', book('one'), actor: a, wall: 10);
      final offline = initial.copy();
      final deletion = initial.copy()
        ..change('s|book|one', null, actor: b, wall: 20);
      offline.change('s|book|two', book('two'), actor: a, wall: 30);
      final merged = combine(offline, deletion);
      expect(merged.visible.containsKey('s|book|one'), false);
      expect(merged.visible.containsKey('s|book|two'), true);
      // Clock skew and concurrent metadata edits never beat a delete.
      offline.change('s|book|one', book('one'), actor: a, wall: 9999999);
      merged.merge(offline);
      expect(merged.visible.containsKey('s|book|one'), false);
      merged.change('s|book|one', book('one'), actor: a, wall: 40);
      merged.merge(deletion);
      expect(merged.visible.containsKey('s|book|one'), true);
    },
  );
  test(
    'merge is commutative, associative and idempotent through random partitions',
    () {
      final rng = Random(78);
      final docs = [SyncDocument(), SyncDocument(), SyncDocument()];
      for (var i = 0; i < 150; i++) {
        final device = rng.nextInt(3), key = 's|book|${rng.nextInt(8)}';
        docs[device].change(
          key,
          rng.nextInt(4) == 0 ? null : {'n': i},
          actor: [a, b, c][device],
          wall: rng.nextInt(1000),
        );
        if (rng.nextBool()) docs[device].merge(docs[(device + 1) % 3]);
        final left = combine(combine(docs[0], docs[1]), docs[2]);
        final right = combine(docs[0], combine(docs[1], docs[2]));
        expect(syncJson(left.toJson()), syncJson(right.toJson()));
        expect(
          syncJson(combine(docs[0], docs[1]).toJson()),
          syncJson(combine(docs[1], docs[0]).toJson()),
        );
        expect(syncJson(combine(left, left).toJson()), syncJson(left.toJson()));
      }
    },
  );
  test(
    'same actor dot with different values fails without partially merging',
    () {
      final left = SyncDocument()..change('key', {'v': 1}, actor: a, wall: 1);
      final right = SyncDocument()
        ..change('key', {'v': 2}, actor: a, wall: 1)
        ..change('other', {'v': 3}, actor: b, wall: 2);
      final before = syncJson(left.toJson());
      expect(() => left.merge(right), throwsFormatException);
      expect(syncJson(left.toJson()), before);
    },
  );
  test(
    'dual slots survive a partial write and retain a fixed file count',
    () async {
      final storage = MemoryStorage(), doc = SyncDocument();
      final exchange = SyncExchange(storage);
      for (var seq = 1; seq <= 8; seq++) {
        doc.change('s|book|one', book('one'), actor: a, wall: seq);
        await exchange.publish(SyncSlot(a, seq, doc.copy()));
      }
      expect(storage.files.length, 2);
      expect((await exchange.readAll())[a]!.sequence, 8);
      storage.corrupt = true;
      await expectLater(
        exchange.publish(SyncSlot(a, 9, doc.copy())),
        throwsA(isA<SyncFailure>()),
      );
      expect((await exchange.readAll())[a]!.sequence, 8);
      storage.files['$a.a.json'] = Uint8List.fromList([1, 2, 3]);
      await expectLater(exchange.readAll(), throwsA(isA<SyncFailure>()));
    },
  );
  test(
    'simultaneous devices write disjoint pairs and converge with deletes',
    () async {
      final storage = MemoryStorage(), exchange = SyncExchange(MemoryStorage());
      final first = SyncDocument()
        ..change('s|book|one', book('one'), actor: a, wall: 1);
      final second = SyncDocument()
        ..change('s|book|two', book('two'), actor: b, wall: 2);
      final actual = SyncExchange(storage);
      await Future.wait([
        actual.publish(SyncSlot(a, 1, first)),
        actual.publish(SyncSlot(b, 1, second)),
      ]);
      final remote = await actual.readAll();
      for (final slot in remote.values) {
        first.merge(slot.document);
        second.merge(slot.document);
      }
      second.change('s|book|one', null, actor: b, wall: 3);
      await Future.wait([
        actual.publish(SyncSlot(a, 2, first)),
        actual.publish(SyncSlot(b, 2, second)),
      ]);
      for (final slot in (await actual.readAll()).values) {
        first.merge(slot.document);
        second.merge(slot.document);
      }
      expect(first.visible.keys, ['s|book|two']);
      expect(syncJson(first.toJson()), syncJson(second.toJson()));
      expect(storage.files.length, 4);
      expect(await exchange.readAll(), isEmpty);
    },
  );
  test('slot integrity and identity are checked', () {
    final slot = SyncSlot(a, 1, SyncDocument());
    final raw = jsonDecode(utf8.decode(slot.encode())) as Map;
    (raw['body'] as Map)['sequence'] = 3;
    expect(
      () => SyncSlot.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(raw))),
        slot.filename,
      ),
      throwsFormatException,
    );
    expect(
      () => SyncSlot.decode(slot.encode(), '$b.b.json'),
      throwsFormatException,
    );
  });
  test(
    'Weiyun imports the official environment instruction without exposing its wrapper',
    () {
      const token = 'abc_def-1234567890.abcdef';
      final transport = WeiyunSyncTransport({
        'password': 'WEIYUN_MCP_TOKEN="$token" python upload.py',
      });
      expect(transport.token, token);
      transport.close();
      final invalid = WeiyunSyncTransport({
        'password': 'invalid\r\nheader: injected',
      });
      expect(() => invalid.token, throwsA(isA<SyncFailure>()));
      invalid.close();
    },
  );
  test(
    'portable snapshot excludes device-only data and roundtrips media progress',
    () {
      final backup = LibraryBackup.capture(
        shelf: [],
        history: [
          {
            'id': 'one',
            'kind': 'book',
            'title': 'One',
            'textOffset': 87,
            'chapterId': 'chapter1',
            'time': 100,
            'secret': 'must-not-sync',
            'cover': '/private/image.jpg',
          },
          {'id': 'local_file', 'kind': 'book'},
        ],
        watched: {
          'series1': {'episode1': 200},
        },
      );
      final snapshot = SyncSnapshot.fromBackup(backup);
      final doc = SyncDocument();
      for (final e in snapshot.values.entries) {
        doc.change(e.key, e.value, actor: a, wall: 100);
      }
      final rebuilt = SyncSnapshot.fromDocument(doc).toBackup();
      expect(rebuilt.history.single['textOffset'], 87);
      expect(rebuilt.history.single.containsKey('secret'), false);
      expect(rebuilt.history.single['cover'], '');
      expect(rebuilt.watched['series1']!['episode1'], 200);
      expect(snapshot.values.keys.any((k) => k.contains('local_')), false);
    },
  );
  test(
    'Weiyun intermediate SHA1 agrees with known empty chaining state and blocks',
    () {
      final small = weiyunUploadHashes(Uint8List.fromList(utf8.encode('abc')));
      expect(small['file_sha'], 'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(small['check_sha'], '0123456789abcdeffedcba9876543210f0e1d2c3');
      expect(small['check_data'], 'YWJj');
      final large = weiyunUploadHashes(Uint8List(524288 + 256));
      expect((large['block_sha_list'] as List).length, 2);
      expect(large['check_data'], base64Encode(Uint8List(128)));
      // Verified against the official Skill's independently implemented SHA1.
      expect(large['check_sha'], '78b337311b79ac8691093a965a29e6a8e57d264f');
      expect(
        (large['block_sha_list'] as List).first,
        'a9a367b44b8ffd0c81c3425071a7fb52861c3834',
      );
    },
  );
  group('library integration', () {
    late Directory temp;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      temp = await Directory.systemTemp.createTemp('fqappx-sync-test-');
      Hive.init(temp.path);
      await LibraryStore.instance.init();
      await ShelfStore.instance.init();
    });
    tearDown(() async {
      await Hive.close();
      await temp.delete(recursive: true);
    });
    test(
      'remote shelf removal does not affect local files and allows re-add',
      () async {
        final shelf = ShelfStore.instance;
        final online = item('one');
        await shelf.add(online);
        await shelf.add(item('local_file'));
        expect(
          await shelf.applySyncedRecords(
            incoming: [],
            acceptsCurrent: (_) => true,
          ),
          true,
        );
        expect(shelf.containsItem(online), false);
        expect(shelf.contains('book', 'local_file'), true);
        await shelf.toggle(online);
        expect(shelf.containsItem(online), true);
      },
    );
    test('conditional writes refuse to overwrite user changes', () async {
      final shelf = ShelfStore.instance, library = LibraryStore.instance;
      await shelf.add(item('one'));
      expect(
        await shelf.applySyncedRecords(
          incoming: [],
          acceptsCurrent: (_) => false,
        ),
        false,
      );
      expect(shelf.contains('book', 'one'), true);
      await library.addHistory({'id': 'one', 'kind': 'book', 'position': 10});
      expect(
        await library.applySyncedRecords(
          history: [],
          watched: {},
          acceptsCurrent: (_, _) => false,
        ),
        false,
      );
      expect((await library.historyEntry('one'))?['position'], 10);
    });
    test(
      'merged history replaces progress and removes known deleted records',
      () async {
        final library = LibraryStore.instance;
        await library.addHistory({'id': 'one', 'kind': 'book', 'position': 10});
        await library.addHistory({'id': 'two', 'kind': 'book', 'position': 20});
        await library.addHistory({
          'id': 'local_file',
          'kind': 'book',
          'position': 5,
        });
        await library.applySyncedRecords(
          history: [
            {'id': 'one', 'kind': 'book', 'position': 30.0},
          ],
          watched: {},
          acceptsCurrent: (_, _) => true,
        );
        expect(await library.historyEntry('two'), null);
        expect((await library.historyEntry('one'))?['position'], 30.0);
        expect((await library.historyEntry('local_file'))?['position'], 5);
      },
    );
  });
}

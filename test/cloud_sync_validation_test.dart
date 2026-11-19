import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/sync/cloud_sync_validation.dart';
import 'package:fqapp/services/sync/sync_transport.dart';
import 'package:fqapp/services/sync/sync_document.dart';

class _Storage implements SyncTransport {
  _Storage(this.files, {this.canOverwrite = true});
  final Map<String, Uint8List> files;
  final bool canOverwrite;
  @override
  Future<void> prepare() async {}
  @override
  Future<List<String>> list() async => files.keys.toList();
  @override
  Future<Uint8List?> read(String name) async => files[name];
  @override
  Future<void> write(String name, Uint8List bytes) async {
    files[!canOverwrite && files.containsKey(name) ? '$name-renamed' : name] =
        Uint8List.fromList(bytes);
  }

  @override
  void close() {}
}

class _ReplacingStorage extends _Storage {
  _ReplacingStorage(super.files);
  bool failAfterDelete = false;
  @override
  Future<void> write(String name, Uint8List bytes) async {
    files.remove(name);
    if (failAfterDelete) throw const SyncFailure('simulated transfer loss');
    await super.write(name, bytes);
  }
}

class _DelayedStorage extends _Storage {
  _DelayedStorage(super.files);
  int writes = 0, staleReads = 0;
  String? pendingName;
  Uint8List? pending;
  @override
  Future<void> write(String name, Uint8List bytes) async {
    writes++;
    if (staleReads > 0) {
      pendingName = name;
      pending = Uint8List.fromList(bytes);
    } else {
      await super.write(name, bytes);
    }
  }

  @override
  Future<Uint8List?> read(String name) async {
    if (pendingName == name && staleReads-- <= 0) {
      files[name] = pending!;
      pendingName = null;
    }
    return files[name];
  }
}

class _LeakingStorage extends _Storage {
  _LeakingStorage(super.files);
  int writes = 0;
  @override
  Future<void> write(String name, Uint8List bytes) async {
    await super.write(name, bytes);
    files['unexpected-${++writes}.json'] = Uint8List(1);
  }
}

void main() {
  test('validation preserves unrelated preexisting files', () async {
    final original = Uint8List.fromList([7, 8, 9]);
    final files = {'keep-existing.txt': original};
    final report = await validateCloudSync(
      'weiyun',
      ({bool forceRefresh = false}) => _Storage(files),
      (_) {},
    );
    expect(report['passed'], true);
    expect(report['fixed_file_count'], 4);
    expect(report['retained_existing_files'], 1);
    expect(report['total_file_count'], 5);
    expect(files['keep-existing.txt'], same(original));
  });
  test(
    'validation rejects newly created extra files even if readback matches',
    () async {
      await expectLater(
        validateCloudSync(
          'weiyun',
          ({bool forceRefresh = false}) => _LeakingStorage({}),
          (_) {},
        ),
        throwsA(isA<SyncFailure>()),
      );
    },
  );
  test(
    'delayed visibility retries reads without creating another write',
    () async {
      const actor = '11111111111111111111111111111111';
      final transport = _DelayedStorage({});
      final exchange = SyncExchange(transport);
      final document = SyncDocument();
      for (var sequence = 1; sequence <= 2; sequence++) {
        document.change(
          's|book|probe',
          {'version': sequence},
          actor: actor,
          wall: sequence,
        );
        await exchange.publish(SyncSlot(actor, sequence, document.copy()));
      }
      transport.staleReads = 2;
      document.change('s|book|probe', {'version': 3}, actor: actor, wall: 3);
      await exchange.publish(SyncSlot(actor, 3, document));
      expect(transport.writes, 3);
      expect(transport.files.length, 2);
      expect((await exchange.readAll())[actor]!.sequence, 3);
    },
  );
  test(
    'losing a deleted inactive slot retains the committed counterpart',
    () async {
      const actor = '11111111111111111111111111111111';
      final files = <String, Uint8List>{};
      final transport = _ReplacingStorage(files);
      final exchange = SyncExchange(transport);
      final document = SyncDocument();
      for (var sequence = 1; sequence <= 2; sequence++) {
        document.change(
          's|book|probe',
          {'version': sequence},
          actor: actor,
          wall: sequence,
        );
        await exchange.publish(SyncSlot(actor, sequence, document.copy()));
      }
      transport.failAfterDelete = true;
      document.change('s|book|probe', {'version': 3}, actor: actor, wall: 3);
      final pending = SyncSlot(actor, 3, document.copy());
      await expectLater(exchange.publish(pending), throwsA(isA<SyncFailure>()));
      final recovered = (await exchange.readAll())[actor]!;
      expect(recovered.sequence, 2);
      expect(recovered.document.visible['s|book|probe']?['version'], 2);
      transport.failAfterDelete = false;
      await exchange.publish(pending);
      expect((await exchange.readAll())[actor]!.sequence, 3);
      expect(files.length, 2);
    },
  );
  test(
    'account validation repeats in the same four files and verifies all merge stages',
    () async {
      final files = <String, Uint8List>{};
      final renewals = <bool>[];
      SyncTransport factory({bool forceRefresh = false}) {
        renewals.add(forceRefresh);
        return _Storage(files);
      }

      for (var run = 0; run < 2; run++) {
        final report = await validateCloudSync('quark', factory, (_) {});
        for (final field in [
          'passed',
          'bidirectional_merge',
          'delete_wins',
          'explicit_readd',
          'fixed_file_overwrites',
          'readback_matches',
          'partial_write_recovery',
          'session_reopen',
        ]) {
          expect(report[field], true, reason: field);
        }
        expect(report['reader_records_modified'], false);
        expect(report['fixed_file_count'], 4);
        expect(files.length, 4);
      }
      expect(renewals, [true, false, true, false]);
    },
  );
  test(
    'validation rejects a backend that silently renames instead of overwriting',
    () async {
      final files = <String, Uint8List>{};
      await expectLater(
        validateCloudSync(
          'tianyi',
          ({bool forceRefresh = false}) => _Storage(files, canOverwrite: false),
          (_) {},
        ),
        throwsA(isA<SyncFailure>()),
      );
    },
  );
}

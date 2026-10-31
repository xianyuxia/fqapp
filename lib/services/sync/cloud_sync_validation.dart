import 'dart:typed_data';
import 'sync_document.dart';
import 'sync_transport.dart';

typedef ValidationTransport = SyncTransport Function({bool forceRefresh});

/// Uses a separate, fixed validation folder and synthetic records. It never
/// reads/applies the reader's bookshelf or overwrites its production snapshots.
Future<Map<String, dynamic>> validateCloudSync(
  String provider,
  ValidationTransport factory,
  void Function(String) progress,
) async {
  const a = '11111111111111111111111111111111';
  const b = '22222222222222222222222222222222';
  const key = 's|book|fqappx_sync_probe';
  Map<String, dynamic> value(int version) => {
    'id': 'fqappx_sync_probe',
    'kind': 'book',
    'title': 'fqappX 同步验证 $version',
    'cover': '',
    'author': '',
    'badge': '',
    'ep': '',
    'seriesId': null,
    'episodeId': null,
    'addedAt': version,
  };
  final canRefresh = {'quark', 'ali', 'onedrive'}.contains(provider);
  var transport = factory(forceRefresh: canRefresh);
  try {
    progress('验证授权、读取专用验证目录');
    var exchange = SyncExchange(transport);
    var remote = await exchange.readAll();
    final existingOtherFiles = (await transport.list())
        .where((name) => !syncSlotPattern.hasMatch(name))
        .toSet();
    if (remote.keys.any((actor) => actor != a && actor != b)) {
      throw const SyncFailure('验证目录已有其他设备数据，停止验证以保护记录');
    }
    final merged = SyncDocument();
    for (final slot in remote.values) {
      merged.merge(slot.document);
    }
    if (merged.records.keys.any((key) => !key.endsWith('|fqappx_sync_probe'))) {
      throw const SyncFailure('验证目录包含其他记录，已停止');
    }
    var seqA = remote[a]?.sequence ?? 0, seqB = remote[b]?.sequence ?? 0;
    final first = merged.copy()..change(key, value(1), actor: a, wall: 1);
    final second = merged.copy()
      ..change(
        'h|book|fqappx_sync_probe',
        {...value(2), 'position': 20.0, 'time': 2},
        actor: b,
        wall: 2,
      );
    progress('验证两台设备同时写入及读取合并');
    await exchange.publish(SyncSlot(a, ++seqA, first));
    await exchange.publish(SyncSlot(b, ++seqB, second));
    remote = await exchange.readAll();
    for (final slot in remote.values) {
      first.merge(slot.document);
      second.merge(slot.document);
    }
    if (first.visible.length != 2) throw const SyncFailure('双向合并验证失败');
    final stale = first.copy()..change(key, value(3), actor: a, wall: 9999999);
    second.change(key, null, actor: b, wall: 3);
    progress('验证远端删除不会被离线旧记录恢复');
    await exchange.publish(SyncSlot(a, ++seqA, stale));
    await exchange.publish(SyncSlot(b, ++seqB, second));
    final deleted = SyncDocument();
    for (final slot in (await exchange.readAll()).values) {
      deleted.merge(slot.document);
    }
    if (deleted.visible.containsKey(key)) throw const SyncFailure('删除防复活验证失败');
    deleted.change(key, value(4), actor: a, wall: 4);
    await exchange.publish(SyncSlot(a, ++seqA, deleted.copy()));
    progress('反复覆盖同一对文件，逐字节读回校验');
    for (var version = 5; version <= 6; version++) {
      deleted.change(key, value(version), actor: a, wall: version);
      await exchange.publish(SyncSlot(a, ++seqA, deleted.copy()));
    }
    progress('模拟写到一半断开，验证另一分区可恢复');
    final pending = SyncSlot(a, seqA + 1, deleted.copy());
    final encoded = pending.encode();
    await transport.write(
      pending.filename,
      Uint8List.fromList(encoded.sublist(0, encoded.length ~/ 2)),
    );
    final fallback = await exchange.readAll();
    if (fallback[a]?.sequence != seqA) throw const SyncFailure('双区损坏恢复验证失败');
    await exchange.publish(SyncSlot(a, ++seqA, deleted.copy()));
    final finalNames = await transport.list();
    final count = finalNames.where(syncSlotPattern.hasMatch).length;
    if (count != 4) throw SyncFailure('固定文件数量验证失败，当前 $count 个文件');
    final otherFiles = finalNames
        .where((name) => !syncSlotPattern.hasMatch(name))
        .toSet();
    if (otherFiles.length != existingOtherFiles.length ||
        !otherFiles.containsAll(existingOtherFiles)) {
      throw const SyncFailure('验证期间产生了额外文件，已停止以避免文件累积');
    }
    transport.close();
    progress('重新建立会话，验证保存的授权仍可读取最新记录');
    transport = factory();
    exchange = SyncExchange(transport);
    final reopened = SyncDocument();
    for (final slot in (await exchange.readAll()).values) {
      reopened.merge(slot.document);
    }
    if (reopened.visible[key]?['title'] != value(6)['title']) {
      throw const SyncFailure('重新登录会话后的内容验证失败');
    }
    return {
      'provider': provider,
      'passed': true,
      'time': DateTime.now().millisecondsSinceEpoch,
      'bidirectional_merge': true,
      'delete_wins': true,
      'explicit_readd': true,
      'fixed_file_overwrites': true,
      'readback_matches': true,
      'partial_write_recovery': true,
      'fixed_file_count': count,
      'total_file_count': finalNames.length,
      'retained_existing_files': existingOtherFiles.length,
      'session_reopen': true,
      'token_refresh': canRefresh
          ? 'passed'
          : provider == 'weiyun'
          ? 'mcp_token'
          : 'web_login_session',
      'reader_records_modified': false,
    };
  } finally {
    transport.close();
  }
}

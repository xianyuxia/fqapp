import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import '../../models/library_backup.dart';
import '../encrypted_hive.dart';
import '../library_backup_service.dart';
import '../library_store.dart';
import '../shelf_store.dart';
import 'sync_document.dart';
import 'sync_snapshot.dart';
import 'sync_transport.dart';
import 'cloud_sync_transport.dart';

String newSyncIdentity() => List.generate(
  16,
  (_) => Random.secure().nextInt(256),
).map((v) => v.toRadixString(16).padLeft(2, '0')).join();

class SyncProvider {
  const SyncProvider(this.id, this.title, this.help, {this.available = true});
  final String id, title, help;
  final bool available;
  static const values = [
    SyncProvider('webdav', 'WebDAV（含坚果云）', '使用专用同步文件夹。坚果云使用账号及应用密码。'),
    SyncProvider('ftp', 'FTP', '使用现有 FTP 服务器；账号和文件以明文传输。'),
    SyncProvider('ftps', 'FTPS', 'FTP over TLS，验证服务器证书并加密数据连接。'),
    SyncProvider('smb', 'SMB', '连接 NAS 或电脑的共享文件夹，需要局域网、VPN 或可达网络。'),
    SyncProvider(
      'onedrive',
      'OneDrive',
      '实验性接入，尚待本版本实机验证。使用 Microsoft Graph；令牌续期依赖 OpenList 公共授权服务，授权范围为整个网盘。',
    ),
    SyncProvider(
      'weiyun',
      '腾讯微云',
      '实验性接入，持续覆盖写入尚待实机验证。使用官方 Skill 的 MCP Token，可粘贴安装指令导入。',
    ),
    SyncProvider('ali', '阿里云盘', '网页版登录凭据，实验性接入，持续覆盖写入及令牌续期尚待本版本实机验证。'),
    SyncProvider('quark', '夸克网盘', '官方客户端授权；固定文件覆盖写入尚待验证。', available: false),
    SyncProvider('tianyi', '天翼云盘', '免费账号已验证小文件读写，持续同步适配中。', available: false),
    SyncProvider(
      'mobile139',
      '中国移动云盘',
      '免费账号已验证小文件读写，持续同步适配中。',
      available: false,
    ),
    SyncProvider('feishu', '飞书', '需要自己的应用与云文档权限，暂未接入。', available: false),
    SyncProvider('123', '123 云盘', '需要开发者授权，暂未接入。', available: false),
    SyncProvider('115', '115 网盘', '开放平台申请与同步接口待验证。', available: false),
  ];
  static SyncProvider byId(String id) =>
      values.firstWhere((v) => v.id == id, orElse: () => values.first);
}

class MultiDeviceSyncService extends ChangeNotifier
    with WidgetsBindingObserver {
  MultiDeviceSyncService._();
  static final instance = MultiDeviceSyncService._();
  static const _secrets = FlutterSecureStorage();
  Box<dynamic>? _box;
  Map<String, String> _config = {};
  Map<String, String> get config => Map.unmodifiable(_config);
  SyncDocument _document = SyncDocument();
  SyncSnapshot _baseline = SyncSnapshot({});
  String _actor = '', _profile = '';
  int _sequence = 0, _failures = 0;
  String _published = '';
  String status = '未配置多端同步';
  DateTime? lastSuccess;
  bool get enabled => _config['enabled'] == 'true';
  bool get ready => _box != null;
  bool busy = false;
  Future<void> _queue = Future.value();
  Future<void>? _running;
  Timer? _timer;
  DateTime? _lastAttempt;
  bool get hasScheduledSync => _timer?.isActive ?? false;
  SyncTransport? _activeTransport;
  bool _stopping = false;
  bool _journalDirty = false;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> initialize() async {
    if (_box != null || !ShelfStore.instance.isReady) return;
    try {
      _box = await EncryptedHive.openBox(
        Hive,
        'multi_device_sync_v1',
        requireEncryption: true,
      );
      final saved = await _secrets.read(key: 'fqappx_sync_config_v1');
      if (saved != null) {
        _config = Map<String, String>.from(jsonDecode(saved) as Map);
      }
      _loadProfile();
      LibraryStore.instance.historyListenable.addListener(_changed);
      LibraryStore.instance.watchedListenable.addListener(_changed);
      ShelfStore.instance.listenable.addListener(_changed);
      WidgetsBinding.instance.addObserver(this);
      if (enabled) {
        _changed();
        unawaited(sync());
      }
    } catch (_) {
      status = '同步初始化失败，本机阅读不受影响';
      notifyListeners();
    }
  }

  void _loadProfile() {
    _profile = _config['profile'] ?? '';
    final raw = _box?.get(_profile);
    _document = SyncDocument();
    _baseline = SyncSnapshot({});
    _actor = newSyncIdentity();
    _sequence = 0;
    _published = '';
    _journalDirty = false;
    lastSuccess = null;
    if (raw is String) {
      final saved = jsonDecode(raw) as Map;
      _actor = saved['actor'] as String;
      if (!syncActorPattern.hasMatch(_actor)) {
        throw const FormatException('设备身份无效');
      }
      _document = SyncDocument.fromJson(
        Map<String, dynamic>.from(saved['document'] as Map),
      );
      _baseline = SyncSnapshot({
        for (final e in (saved['baseline'] as Map).entries)
          e.key as String: Map<String, dynamic>.from(e.value as Map),
      });
      _sequence = saved['sequence'] as int;
      _published = saved['published'] as String;
      final timestamp = saved['lastSuccess'] as int?;
      if (timestamp != null) {
        lastSuccess = DateTime.fromMillisecondsSinceEpoch(timestamp);
      }
      // Recover a crash between a library write and the matching journal write.
      final pending = saved['pending'];
      if (pending is Map) _pendingRecovery = Map<String, dynamic>.from(pending);
    }
    status = enabled ? '等待同步' : '未启用多端同步';
  }

  Map<String, dynamic>? _pendingRecovery;
  Future<void> _persist({Map<String, dynamic>? pending}) async {
    await _box!.put(
      _profile,
      jsonEncode({
        'actor': _actor,
        'sequence': _sequence,
        'published': _published,
        'document': _document.toJson(),
        'baseline': _baseline.values,
        'lastSuccess': lastSuccess?.millisecondsSinceEpoch,
        'pending': ?pending,
      }),
    );
    await _box!.flush();
    _journalDirty = false;
  }

  Future<void> configure(Map<String, String> config) async {
    if (!ready) throw const SyncFailure('本机同步存储尚未准备好');
    if (_running != null) await _running;
    await _serial(() async {
      _timer?.cancel();
      final changed = [
        'provider',
        'endpoint',
        'username',
        'password',
        'domain',
        'implicit',
      ].any((key) => config[key] != _config[key]);
      final next = {
        ...config,
        'profile': changed || _profile.isEmpty ? newSyncIdentity() : _profile,
      };
      await _secrets.write(
        key: 'fqappx_sync_config_v1',
        value: jsonEncode(next),
      );
      _config = next;
      _pendingRecovery = null;
      _loadProfile();
      if (enabled) await _capture();
      notifyListeners();
    });
    if (enabled) unawaited(sync());
  }

  void _changed() {
    if (!enabled || !ready || _stopping) return;
    unawaited(
      _serial(() async {
        try {
          if (await _capture()) _schedule();
        } catch (_) {
          status = '本地同步日志写入失败，记录仍保存在本机';
          _schedule();
          notifyListeners();
        }
      }),
    );
  }

  void _schedule() {
    if (_timer?.isActive ?? false) return;
    // Persist every change immediately; coalesce network writes to avoid quota
    // exhaustion while a player updates its position every few seconds.
    final elapsed = DateTime.now().difference(_lastAttempt ?? DateTime(2000));
    final wait = elapsed.inSeconds >= 30 ? 2 : 30 - elapsed.inSeconds;
    _timer = Timer(Duration(seconds: wait), () => unawaited(sync()));
  }

  Future<SyncSnapshot> _current() async =>
      SyncSnapshot.fromBackup(await LibraryBackupService().capture());
  Future<bool> _capture() async {
    final current = await _current();
    final pending = _pendingRecovery;
    if (pending != null) {
      final desired = Map<String, dynamic>.from(pending);
      final keys = {..._baseline.values.keys, ...desired.keys};
      for (final key in keys) {
        if (syncJson(current.values[key]) == syncJson(desired[key])) {
          if (desired[key] == null) {
            _baseline.values.remove(key);
          } else {
            _baseline.values[key] = Map<String, dynamic>.from(
              desired[key] as Map,
            );
          }
        }
      }
      _pendingRecovery = null;
    }
    final keys = {...current.values.keys, ..._baseline.values.keys};
    final firstCapture = _box!.get(_profile) == null;
    var changed = false;
    for (final key in keys) {
      if (syncJson(current.values[key]) == syncJson(_baseline.values[key])) {
        continue;
      }
      _document.change(
        key,
        current.values[key],
        actor: _actor,
        wall: firstCapture
            ? ((current.values[key]?['time'] ??
                          current.values[key]?['addedAt'] ??
                          current.values[key]?['at'] ??
                          0)
                      as num)
                  .toInt()
            : DateTime.now().millisecondsSinceEpoch,
      );
      changed = true;
    }
    _baseline = current;
    // Also persist recovery reconciliation when it produced no new operation.
    _journalDirty =
        _journalDirty ||
        changed ||
        pending != null ||
        _box!.get(_profile) == null;
    if (_journalDirty) {
      await _persist();
    }
    return changed;
  }

  SyncTransport _transport() {
    final provider = _config['provider'];
    if (provider == 'webdav') {
      return WebDavSyncTransport(
        _config['endpoint'] ?? '',
        _config['username'] ?? '',
        _config['password'] ?? '',
      );
    }
    if ({'ftp', 'ftps', 'smb'}.contains(provider)) {
      return NativeSyncTransport(_config);
    }
    return createCloudSyncTransport(_config, (updates) async {
      _config = {..._config, ...updates};
      await _secrets.write(
        key: 'fqappx_sync_config_v1',
        value: jsonEncode(_config),
      );
    });
  }

  Future<void> sync() {
    if (!ready || !enabled || _stopping) return Future.value();
    if (_running != null) return _running!;
    final future = _sync();
    _running = future;
    return future.whenComplete(() => _running = null);
  }

  Future<void> _sync() async {
    busy = true;
    status = '正在合并多端记录…';
    notifyListeners();
    _timer?.cancel();
    _lastAttempt = DateTime.now();
    SyncTransport? transport;
    try {
      await _serial(_capture);
      transport = _transport();
      _activeTransport = transport;
      final exchange = SyncExchange(transport);
      final slots = await exchange.readAll();
      late SyncSlot outgoing;
      await _serial(() async {
        await _capture();
        final merged = _document.copy();
        for (final slot in slots.values) {
          merged.merge(slot.document);
        }
        final desired = SyncSnapshot.fromDocument(merged);
        _document = merged;
        if ((slots[_actor]?.sequence ?? 0) > _sequence) {
          _sequence = slots[_actor]!.sequence;
        }
        // Write the intent first so a process death cannot turn a downloaded
        // deletion into a fresh local add on next startup.
        await _persist(pending: desired.values);
        _pendingRecovery = desired.values;
        final backup = desired.toBackup();
        final shelfApplied = await ShelfStore.instance.applySyncedRecords(
          incoming: backup.shelf,
          acceptsCurrent: (shelf) => SyncSnapshot.fromBackup(
            LibraryBackup.capture(shelf: shelf, history: [], watched: {}),
          ).sameDomain(_baseline, 's|'),
        );
        if (shelfApplied) _baseline.replaceDomain(desired, 's|');
        final libraryApplied = await LibraryStore.instance.applySyncedRecords(
          history: backup.history,
          watched: backup.watched,
          acceptsCurrent: (history, watched) {
            final current = SyncSnapshot.fromBackup(
              LibraryBackup.capture(
                shelf: [],
                history: history,
                watched: watched,
              ),
            );
            return current.sameDomain(_baseline, 'h|') &&
                current.sameDomain(_baseline, 'w|');
          },
        );
        if (libraryApplied) {
          _baseline.replaceDomain(desired, 'h|');
          _baseline.replaceDomain(desired, 'w|');
        }
        _pendingRecovery = null;
        await _persist();
        await _capture(); // Capture user writes that raced the conditional apply.
        outgoing = SyncSlot(_actor, _sequence + 1, _document.copy());
      });
      final fingerprint = sha256
          .convert(utf8.encode(syncJson(outgoing.document.toJson())))
          .toString();
      // Recreate our slots if a user intentionally changed/emptied the folder.
      final didPublish =
          fingerprint != _published || !slots.containsKey(_actor);
      if (didPublish) {
        await exchange.publish(outgoing);
      }
      await _serial(() async {
        if (didPublish) _sequence = outgoing.sequence;
        _published = fingerprint;
        lastSuccess = DateTime.now();
        await _persist();
        if (syncJson(_document.toJson()) !=
            syncJson(outgoing.document.toJson())) {
          _schedule();
        }
      });
      _failures = 0;
      status = '同步完成';
    } catch (error) {
      _failures++;
      status = error is SyncFailure
          ? error.message
          : error is FormatException
          ? error.message
          : '同步未完成，本机记录已保留';
      if (enabled && !_stopping) {
        _timer = Timer(
          Duration(seconds: min(300, 30 * (1 << min(_failures, 4)))),
          () => unawaited(sync()),
        );
      }
    } finally {
      transport?.close();
      _activeTransport = null;
      busy = false;
      notifyListeners();
    }
  }

  /// Called before closing Hive on desktop, and by integration tests. Cancels
  /// network IO but flushes the local journal; no reading records are removed.
  Future<void> shutdown() async {
    _stopping = true;
    _timer?.cancel();
    _activeTransport?.close();
    await _running;
    if (_box == null) return;
    LibraryStore.instance.historyListenable.removeListener(_changed);
    LibraryStore.instance.watchedListenable.removeListener(_changed);
    ShelfStore.instance.listenable.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    if (enabled) await _serial(_capture);
    _timer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(sync());
    if (state == AppLifecycleState.paused) _changed();
  }
}

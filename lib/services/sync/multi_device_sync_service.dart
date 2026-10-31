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
import 'cloud_sync_validation.dart';
import '../platform_channel.dart';

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
      '通过微软官方页面授权。文件直接通过 Microsoft Graph 读写；授权及令牌续期依赖 OpenList 公共服务，授权范围为整个网盘。',
    ),
    SyncProvider(
      'weiyun',
      '腾讯微云',
      '官方文件授权，支持 QQ / 跨设备微信扫码及官方指令导入。固定快照按双区轮换，仅替换非当前分区。',
    ),
    SyncProvider('ali', '阿里云盘', '官方手机网页登录，使用网页授权凭据直接读写，支持刷新令牌；登录后可验证持续同步。'),
    SyncProvider(
      'quark',
      '夸克网盘',
      '官方客户端授权，无需粘贴授权码，授权后返回本应用。固定快照通过双区轮换替换；夸克回收站可能保留旧快照。',
    ),
    SyncProvider('tianyi', '天翼云盘', '官方手机网页登录，使用覆盖提交保存固定快照。'),
    SyncProvider('mobile139', '中国移动云盘', '官方手机网页登录，登录后可运行持续同步验证。'),
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
  final Map<String, Map<String, String>> _providerConfigs = {};
  Map<String, String> get config => Map.unmodifiable(_config);
  Map<String, String> configFor(String provider) => Map.unmodifiable(
    _providerConfigs[provider] ?? {'provider': provider, 'enabled': 'false'},
  );
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
  bool validating = false;
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
    var stage = 'open_journal';
    try {
      _box = await EncryptedHive.openBox(
        Hive,
        'multi_device_sync_v1',
        requireEncryption: true,
      );
      stage = 'read_config';
      final saved = await _secrets.read(key: 'fqappx_sync_config_v1');
      if (saved != null) {
        _config = Map<String, String>.from(jsonDecode(saved) as Map);
      }
      stage = 'read_profiles';
      final profiles = await _secrets.read(key: 'fqappx_sync_providers_v1');
      if (profiles != null) {
        final raw = jsonDecode(profiles) as Map;
        for (final entry in raw.entries) {
          _providerConfigs[entry.key as String] = Map<String, String>.from(
            entry.value as Map,
          );
        }
      }
      if (_config['provider'] case final String provider) {
        _providerConfigs.putIfAbsent(provider, () => Map.of(_config));
        final cached = _providerConfigs[provider]!;
        if (cached['profile'] == _config['profile'] &&
            cached['password'] != null) {
          _config = {..._config, 'password': cached['password']!};
        }
      }
      stage = 'load_journal';
      _loadProfile();
      stage = 'watch_stores';
      LibraryStore.instance.historyListenable.addListener(_changed);
      LibraryStore.instance.watchedListenable.addListener(_changed);
      ShelfStore.instance.listenable.addListener(_changed);
      WidgetsBinding.instance.addObserver(this);
      stage = 'action_handlers';
      await _initializeDebugActions();
      await _debugState('ready');
      if (enabled) {
        _changed();
        unawaited(sync());
      }
    } catch (error) {
      await _debugState(stage, error.runtimeType.toString());
      status = '同步初始化失败，本机阅读不受影响';
      notifyListeners();
    }
  }

  static const _actions = AppMethodChannel('fqapp/cloud_actions');
  Future<void> _debugState(String stage, [String? errorType]) async {
    try {
      await const AppMethodChannel('fqapp/cloud_storage').invokeMethod(
        'recordServiceState',
        {'stage': stage, 'error_type': ?errorType},
      );
    } catch (_) {}
  }

  bool _actionBusy = false;
  Future<void> _initializeDebugActions() async {
    try {
      await _actions.setMethodCallHandler((call) async {
        if (call.method == 'action' && call.arguments is Map) {
          unawaited(
            _handleDebugAction(
              Map<String, dynamic>.from(call.arguments as Map),
            ),
          );
        }
      });
      final pending = await _actions.invokeMapMethod<String, dynamic>(
        'pending',
      );
      if (pending != null) unawaited(_handleDebugAction(pending));
    } catch (_) {} // Channel is absent on non-Android/test hosts.
  }

  Future<void> _handleDebugAction(Map<String, dynamic> action) async {
    if (_actionBusy || validating) return;
    final provider = action['provider'];
    if (provider is! String ||
        !{
          'quark',
          'tianyi',
          'mobile139',
          'ali',
          'weiyun',
          'onedrive',
        }.contains(provider)) {
      return;
    }
    _actionBusy = true;
    await _debugState('action_$provider');
    try {
      if (action['action'] == 'login') {
        status = '正在打开 ${SyncProvider.byId(provider).title} 官方登录';
        notifyListeners();
        final token = await const AppMethodChannel(
          'fqapp/cloud_login',
        ).invokeMethod<String>('login', {'provider': provider});
        if (token == null || token.isEmpty) {
          status = '授权未完成，阅读记录未改动';
          return;
        }
        await rememberProvider({
          ...configFor(provider),
          'provider': provider,
          'password': token,
          'enabled': 'false',
        });
      }
      if (action['action'] == 'login' || action['action'] == 'validate') {
        await validateProvider(Map.of(configFor(provider)));
      }
    } catch (error) {
      status = error is SyncFailure ? error.message : '授权或验证尚未完成，阅读记录未改动';
    } finally {
      _actionBusy = false;
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
    final submitted = Map<String, String>.of(config);
    final original = Map<String, String>.of(
      _providerConfigs[submitted['provider']] ?? {},
    );
    final followsSavedCredential =
        original['profile'] != null &&
        (submitted['password'] ?? '') == (original['password'] ?? '');
    if (_running != null) await _running;
    await _serial(() async {
      _timer?.cancel();
      final prior =
          _providerConfigs[submitted['provider']] ?? <String, String>{};
      if (followsSavedCredential && prior['profile'] != original['profile']) {
        throw const SyncFailure('登录状态已变化，请重新打开同步设置后保存');
      }
      final effective = {
        ...submitted,
        if (followsSavedCredential) 'password': prior['password'] ?? '',
      };
      final changed = [
        'provider',
        'endpoint',
        'username',
        'password',
        'domain',
        'implicit',
      ].any((key) => effective[key] != prior[key]);
      final next = {
        ...effective,
        'profile': changed || (prior['profile'] ?? '').isEmpty
            ? newSyncIdentity()
            : prior['profile']!,
      };
      await _secrets.write(
        key: 'fqappx_sync_config_v1',
        value: jsonEncode(next),
      );
      _config = next;
      _providerConfigs[next['provider']!] = Map.of(next);
      await _saveProviderConfigs();
      _pendingRecovery = null;
      _loadProfile();
      if (enabled) await _capture();
      notifyListeners();
    });
    if (enabled) unawaited(sync());
  }

  Future<void> _saveProviderConfigs() => _secrets.write(
    key: 'fqappx_sync_providers_v1',
    value: jsonEncode(_providerConfigs),
  );

  /// Remember a login without enabling sync or changing the active backend.
  Future<void> rememberProvider(Map<String, String> config) async {
    if (_running != null) await _running;
    await _serial(() async {
      final provider = config['provider']!;
      final prior = _providerConfigs[provider] ?? <String, String>{};
      final same = [
        'endpoint',
        'username',
        'password',
        'domain',
        'implicit',
      ].every((key) => (config[key] ?? '') == (prior[key] ?? ''));
      _providerConfigs[provider] = {
        ...config,
        'enabled': 'false',
        'profile': same && prior['profile'] != null
            ? prior['profile']!
            : newSyncIdentity(),
      };
      await _saveProviderConfigs();
      notifyListeners();
    });
  }

  Future<void> saveProviderCredentials(
    String provider,
    Map<String, String> updates, {
    String? profile,
  }) => _serial(() async {
    final prior = _providerConfigs[provider];
    if (prior == null) return;
    final target = profile ?? prior['profile'];
    if (prior['profile'] == target) {
      _providerConfigs[provider] = {...prior, ...updates};
      await _saveProviderConfigs();
    }
    if (_config['provider'] == provider && _config['profile'] == target) {
      _config = {..._config, ...updates};
      await _secrets.write(
        key: 'fqappx_sync_config_v1',
        value: jsonEncode(_config),
      );
    }
    notifyListeners();
  });

  Map<String, dynamic>? validationFor(String provider) {
    final raw = _box?.get('validation:$provider');
    return raw is String
        ? Map<String, dynamic>.from(jsonDecode(raw) as Map)
        : null;
  }

  Future<void> validateProvider(Map<String, String> form) async {
    if (validating) throw const SyncFailure('请等待当前验证完成');
    if (_running != null) await _running;
    validating = true;
    notifyListeners();
    final provider = form['provider']!;
    var step = '验证授权、读取专用验证目录';
    try {
      await rememberProvider(form);
      final report = await validateCloudSync(
        provider,
        ({bool forceRefresh = false}) => transportFor({
          ...configFor(provider),
          'endpoint': 'fqappx-validation-v3',
          if (forceRefresh) 'forceRefresh': 'true',
        }),
        (message) {
          step = message;
          status = '${SyncProvider.byId(provider).title}：$message';
          notifyListeners();
        },
      );
      await _box!.put('validation:$provider', jsonEncode(report));
      await _box!.flush();
      await _recordValidation(report);
      status = '${SyncProvider.byId(provider).title}：持续同步验证通过';
    } catch (error) {
      status = error is SyncFailure ? error.message : '验证未完成，阅读记录未改动';
      final report = {
        'provider': provider,
        'passed': false,
        'time': DateTime.now().millisecondsSinceEpoch,
        'error': status,
        'step': step,
        'reader_records_modified': false,
      };
      await _box!.put('validation:$provider', jsonEncode(report));
      await _recordValidation(report);
      rethrow;
    } finally {
      validating = false;
      notifyListeners();
      if (enabled) _schedule();
    }
  }

  Future<void> _recordValidation(Map<String, dynamic> report) async {
    try {
      await const AppMethodChannel(
        'fqapp/cloud_storage',
      ).invokeMethod('recordValidation', report);
    } catch (_) {} // Debug evidence is optional; never affects production sync.
  }

  SyncTransport transportFor(Map<String, String> config) {
    final provider = config['provider'];
    if (provider == 'webdav') {
      return WebDavSyncTransport(
        config['endpoint'] ?? '',
        config['username'] ?? '',
        config['password'] ?? '',
      );
    }
    if ({'ftp', 'ftps', 'smb'}.contains(provider)) {
      return NativeSyncTransport(config);
    }
    return createCloudSyncTransport(
      config,
      (updates) => saveProviderCredentials(
        provider!,
        updates,
        profile: config['profile'],
      ),
    );
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
    return transportFor(_config);
  }

  Future<void> sync() {
    if (!ready || !enabled || _stopping || validating) return Future.value();
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
    await _actions.setMethodCallHandler(null);
    if (enabled) await _serial(_capture);
    _timer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(sync());
    if (state == AppLifecycleState.paused) _changed();
  }
}

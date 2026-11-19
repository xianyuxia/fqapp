import 'package:flutter/services.dart' show SystemChannels;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/multi_device_sync_page.dart';
import 'package:fqapp/pages/sync_setup_page.dart';
import 'package:fqapp/services/sync/sync_settings_store.dart';
import 'package:fqapp/services/sync/sync_setup_session.dart';
import 'package:fqapp/widgets/settings/settings_widgets.dart';

class SettingsFake extends ChangeNotifier implements SyncSettingsStore {
  @override
  Map<String, String> config = {};
  @override
  Map<String, String> configFor(String provider) =>
      config['provider'] == provider ? config : {'provider': provider};
  @override
  bool get enabled => config['enabled'] == 'true';
  @override
  bool busy = false;
  @override
  String status = '同步完成';
  @override
  DateTime? lastSuccess;
  int saves = 0;
  @override
  Future<void> configure(Map<String, String> value) async {
    config = value;
    saves++;
    notifyListeners();
  }

  @override
  Future<void> setAutoSync(bool value) async {
    config = {...config, 'enabled': '$value'};
    notifyListeners();
  }

  @override
  Future<void> sync() async {}
}

class SessionFake implements SyncSetupSession {
  static const savedFolder = SyncFolder(
    'selected-id',
    '同步档案',
    parent: 'root',
    path: '/同步档案/',
  );
  @override
  final Map<String, String> config;
  final List<SyncFolder> rootFolders;
  SessionFake(this.config, {this.rootFolders = const [savedFolder]});
  @override
  SyncFolder get root => const SyncFolder('root', '我的网盘', path: '/');
  bool closed = false;
  final createdFolders = <String>[];
  @override
  Future<List<SyncFolder>> folders(SyncFolder folder) async =>
      folder.id == 'root' ? rootFolders : [];
  @override
  Future<SyncFolder> createFolder(SyncFolder parent, String name) async {
    createdFolders.add(name);
    return SyncFolder('new-id', name, parent: parent.id, path: '/$name/');
  }

  @override
  Map<String, String> select(SyncFolder folder) => {
    ...config,
    'folderId': folder.id,
    'folderParent': folder.parent,
    'endpoint': folder.path,
  };
  @override
  void close() {
    closed = true;
  }
}

class _WebDavSettingsFake extends SettingsFake implements WebDavSyncSettings {
  @override
  bool get needsWebDavReview => false;

  @override
  Future<WebDavSyncPreview> previewWebDav(Map<String, String> config) async =>
      const WebDavSyncPreview(
        revision: 'previewed',
        cloudShelf: 1,
        cloudHistory: 2,
        cloudEpisodes: 3,
        localShelf: 3,
        localHistory: 3,
        localEpisodes: 3,
        mergedShelf: 4,
        mergedHistory: 5,
        mergedEpisodes: 6,
        localRemovals: 0,
      );
}

void main() {
  testWidgets('WebDAV uses one format and requires a preview before save', (
    tester,
  ) async {
    final store = _WebDavSettingsFake();
    await tester.pumpWidget(
      MaterialApp(
        home: SyncSetupPage(
          provider: 'webdav',
          store: store,
          login: (_) async => null,
          openSession: (config) async => SessionFake(config),
        ),
      ),
    );
    expect(find.text('同步格式'), findsNothing);
    expect(find.text('fqappx 原有格式'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('sync-field-服务器地址')),
      'https://dav.example.test/',
    );
    await tester.ensureVisible(find.text('登录并继续'));
    await tester.tap(find.text('登录并继续'));
    await tester.pumpAndSettle();
    expect(find.textContaining('创建并使用目录'), findsNothing);
    await tester.tap(find.byTooltip('新建目录'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步档案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用此目录'));
    await tester.pumpAndSettle();

    final save = find.widgetWithText(FilledButton, '保存并启用');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.ensureVisible(find.text('预览同步结果'));
    await tester.tap(find.text('预览同步结果'));
    await tester.pumpAndSettle();
    expect(find.textContaining('预计合并：番茄收藏 4 项'), findsOneWidget);
    expect(store.saves, 0);
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(store.config.containsKey('webdavFormat'), isFalse);
    expect(store.config['webdavPreview'], 'previewed');
    expect(store.saves, 1);
  });

  testWidgets(
    'disabled sync shows only the top shared switch; picker matches settings dialog',
    (tester) async {
      final store = SettingsFake();
      await tester.pumpWidget(
        MaterialApp(home: MultiDeviceSyncPage(store: store)),
      );
      expect(find.byType(SettingsSwitch), findsOneWidget);
      expect(find.text('存储服务'), findsNothing);
      expect(find.text('立即同步'), findsNothing);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('存储服务'));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.text('WebDAV'), findsWidgets);
      final options = tester.widgetList<RadioListTile<String>>(
        find.byType(RadioListTile<String>),
      );
      expect(options.map((option) => (option.title as Text).data), [
        'WebDAV',
        '阿里云盘',
        '夸克网盘',
        '天翼云盘',
        '中国移动云盘',
        '腾讯微云（操作繁琐）',
        'FTP',
        'FTPS',
        'SMB',
      ]);
      for (final hidden in [
        '飞书',
        '123 云盘',
        '115 网盘',
        'OneDrive',
        'WebDAV（含坚果云）',
      ]) {
        expect(find.text(hidden), findsNothing);
      }
      expect(store.saves, 0);
    },
  );

  testWidgets(
    'login precedes real folder selection; only final save enables sync',
    (tester) async {
      final store = SettingsFake()
        ..config = {'provider': 'weiyun', 'endpoint': '/同步档案/'};
      var logins = 0, opens = 0;
      late SessionFake session;
      await tester.pumpWidget(
        MaterialApp(
          home: SyncSetupPage(
            provider: 'weiyun',
            store: store,
            login: (_) async {
              logins++;
              return 'private-token-value';
            },
            openSession: (config) async {
              opens++;
              return session = SessionFake(
                config,
                rootFolders: const [
                  SyncFolder('other', '普通文件夹', parent: 'root'),
                  SyncFolder('default', '什锦铺-云同步', parent: 'root'),
                  SessionFake.savedFolder,
                ],
              );
            },
          ),
        ),
      );
      expect(find.text('登录腾讯微云'), findsOneWidget);
      expect(find.text('申请并粘贴 API Key'), findsOneWidget);
      expect(opens, 0);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.text('密码或扫码登录'));
      await tester.pumpAndSettle();
      expect(logins, 1);
      expect(opens, 1);
      expect(find.text('同步档案'), findsOneWidget);
      expect(find.text('什锦铺-云同步'), findsOneWidget);
      expect(find.textContaining('创建并使用目录'), findsNothing);
      expect(
        tester.getTopLeft(find.text('同步档案')).dy,
        lessThan(tester.getTopLeft(find.text('什锦铺-云同步')).dy),
      );
      expect(
        tester.getTopLeft(find.text('什锦铺-云同步')).dy,
        lessThan(tester.getTopLeft(find.text('普通文件夹')).dy),
      );
      expect(store.saves, 0);
      await tester.tap(find.byTooltip('新建目录'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '什锦铺-云同步',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同步档案'));
      await tester.pumpAndSettle();
      expect(find.text('上一级'), findsOneWidget);
      await tester.tap(find.text('上一级'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(SettingsRow, '同步档案'),
          matching: find.widgetWithText(TextButton, '使用'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认同步设置'), findsOneWidget);
      expect(find.text('/同步档案/'), findsOneWidget);
      expect(find.text('private-token-value'), findsNothing);
      expect(store.saves, 0);
      await tester.tap(find.text('保存并启用'));
      await tester.pumpAndSettle();
      expect(store.enabled, true);
      expect(store.saves, 1);
      expect(store.config['folderId'], 'selected-id');
      expect(store.config['folderParent'], 'root');
      expect(session.closed, true);
    },
  );

  testWidgets(
    'turning off hides settings and persists disable without changing directory',
    (tester) async {
      final store = SettingsFake()
        ..config = {
          'provider': 'webdav',
          'enabled': 'true',
          'endpoint': 'https://server/sync/',
        };
      await tester.pumpWidget(
        MaterialApp(home: MultiDeviceSyncPage(store: store)),
      );
      expect(find.text('存储服务'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(store.enabled, false);
      expect(store.config['endpoint'], 'https://server/sync/');
      expect(find.text('存储服务'), findsNothing);
    },
  );

  testWidgets(
    'Weiyun shows the official site guidance and accepts an API Key',
    (tester) async {
      final store = SettingsFake();
      var opens = 0;
      late SessionFake session;
      const apiKey = 'test-api-key-for-weiyun';
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': apiKey};
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SyncSetupPage(
            provider: 'weiyun',
            store: store,
            login: (_) async => null,
            openSession: (config) async {
              opens++;
              expect(config['password'], apiKey);
              return session = SessionFake(config);
            },
          ),
        ),
      );
      await tester.tap(find.text('申请并粘贴 API Key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开微云官网申请'));
      await tester.pumpAndSettle();
      expect(find.text('在微云官网申请 API Key'), findsOneWidget);
      expect(find.textContaining('右上角的「登录」'), findsOneWidget);
      expect(find.textContaining('电脑或另一台手机'), findsOneWidget);
      expect(
        find.textContaining('https://www.weiyun.com/authorize'),
        findsOneWidget,
      );
      expect(find.text('继续打开官网'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('从剪贴板粘贴'), findsOneWidget);
      expect(find.text('API Key'), findsOneWidget);
      expect(opens, 0);
      await tester.tap(find.text('从剪贴板粘贴'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isTrue,
      );
      await tester.tap(find.text('验证并继续'));
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(store.saves, 0);
      await tester.tap(find.text('创建并使用目录【什锦铺-云同步】'));
      await tester.pumpAndSettle();
      expect(session.createdFolders, ['什锦铺-云同步']);
      expect(find.text('/什锦铺-云同步/'), findsOneWidget);
      expect(find.text('确认同步设置'), findsOneWidget);
      expect(store.saves, 0);
      await tester.tap(find.text('保存并启用'));
      await tester.pumpAndSettle();
      expect(store.config['folderId'], 'new-id');
      expect(store.saves, 1);
    },
  );
}

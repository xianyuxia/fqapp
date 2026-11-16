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
  Map<String, String> configFor(String provider) => {'provider': provider};
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
  @override
  final Map<String, String> config;
  SessionFake(this.config);
  @override
  SyncFolder get root => const SyncFolder('root', '我的网盘', path: '/');
  bool closed = false;
  @override
  Future<List<SyncFolder>> folders(SyncFolder folder) async =>
      folder.id == 'root'
      ? [
          const SyncFolder(
            'selected-id',
            '同步档案',
            parent: 'root',
            path: '/同步档案/',
          ),
        ]
      : [];
  @override
  Future<SyncFolder> createFolder(SyncFolder parent, String name) async =>
      SyncFolder('new-id', name, parent: parent.id, path: '/$name/');
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

void main() {
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
      final store = SettingsFake();
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
              return session = SessionFake(config);
            },
          ),
        ),
      );
      expect(find.text('登录腾讯微云'), findsWidgets);
      expect(opens, 0);
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '登录腾讯微云'));
      await tester.pumpAndSettle();
      expect(logins, 1);
      expect(opens, 1);
      expect(find.text('同步档案'), findsOneWidget);
      expect(store.saves, 0);
      await tester.tap(find.text('同步档案'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用此目录'));
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
    'manual token is requested after folder name and retained only on save',
    (tester) async {
      final store = SettingsFake();
      var opens = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SyncSetupPage(
            provider: 'weiyun',
            store: store,
            login: (_) async => null,
            openSession: (config) async {
              opens++;
              return SessionFake(config);
            },
          ),
        ),
      );
      await tester.tap(find.text('使用已有 Token'));
      await tester.pumpAndSettle();
      expect(find.text('同步目录名称'), findsOneWidget);
      expect(find.text('MCP Token / 官方安装指令'), findsNothing);
      await tester.enterText(find.byType(TextField), '同步档案');
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('MCP Token / 官方安装指令'), findsOneWidget);
      expect(opens, 0);
      await tester.enterText(find.byType(TextField), 'private-token-value');
      await tester.tap(find.text('验证并继续'));
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(store.saves, 0);
      expect(find.text('确认同步设置'), findsOneWidget);
    },
  );
}

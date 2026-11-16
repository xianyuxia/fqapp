import 'package:material_ui/material_ui.dart';

import '../services/platform_channel.dart';
import '../services/sync/multi_device_sync_service.dart';
import '../services/sync/sync_settings_store.dart';
import '../services/sync/sync_setup_session.dart';
import '../services/sync/sync_transport.dart';
import '../widgets/settings/settings_widgets.dart';
import 'sync_folder_picker.dart';

typedef CloudSyncLogin = Future<String?> Function(String provider);
Future<String?> loginCloudSync(String provider) => const AppMethodChannel(
  'fqapp/cloud_login',
).invokeMethod<String>('login', {'provider': provider});

class SyncSetupPage extends StatefulWidget {
  const SyncSetupPage({
    super.key,
    required this.provider,
    required this.store,
    required this.openSession,
    required this.login,
  });
  final String provider;
  final SyncSettingsStore store;
  final SyncSetupFactory openSession;
  final CloudSyncLogin login;
  @override
  State<SyncSetupPage> createState() => _SyncSetupPageState();
}

class _SyncSetupPageState extends State<SyncSetupPage> {
  final address = TextEditingController(),
      username = TextEditingController(),
      password = TextEditingController(),
      domain = TextEditingController(),
      folderName = TextEditingController(text: 'fqappx-sync');
  SyncSetupSession? session;
  Map<String, String>? selection;
  bool busy = false, implicit = false, manual = false;
  int step = 0;
  String? error;
  String get provider => widget.provider;
  bool get cloud => !{'webdav', 'ftp', 'ftps', 'smb'}.contains(provider);
  String get title => SyncProvider.byId(provider).title;
  @override
  void initState() {
    super.initState();
    final saved = widget.store.configFor(provider);
    address.text = saved['endpoint'] ?? '';
    username.text = saved['username'] ?? '';
    password.text = saved['password'] ?? '';
    domain.text = saved['domain'] ?? '';
    implicit = saved['implicit'] == 'true';
  }

  @override
  void dispose() {
    for (final controller in [
      address,
      username,
      password,
      domain,
      folderName,
    ]) {
      controller.dispose();
    }
    session?.close();
    super.dispose();
  }

  Map<String, String> form() => {
    'provider': provider,
    'endpoint': address.text.trim(),
    'username': username.text.trim(),
    'password': password.text,
    'domain': domain.text.trim(),
    'implicit': '$implicit',
    'enabled': 'false',
    if (password.text == widget.store.configFor(provider)['password'] &&
        widget.store.configFor(provider)['profile'] != null)
      'profile': widget.store.configFor(provider)['profile']!,
  };

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = failure is SyncFailure
              ? failure.message
              : '操作未完成，请检查连接或重新登录',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> login() => run(() async {
    final token = await widget.login(provider);
    if (!mounted || token == null || token.isEmpty) return;
    password.text = token;
    await connect();
  });

  Future<void> connect() async {
    final opened = await widget.openSession(form());
    if (!mounted) {
      opened.close();
      return;
    }
    session?.close();
    session = opened;
    await opened.folders(opened.root);
    if (!mounted) return;
    setState(() => step = 1);
    await chooseFolder();
  }

  Future<void> chooseFolder() async {
    final selected = await Navigator.of(context).push<SyncFolder>(
      MaterialPageRoute(builder: (_) => SyncFolderPicker(session: session!)),
    );
    if (!mounted || selected == null) return;
    setState(() {
      selection = session!.select(selected);
      step = manual ? 3 : 2;
    });
  }

  Future<void> finishToken() => run(() async {
    if (password.text.trim().isEmpty) throw const SyncFailure('请填写 Token');
    final opened = await widget.openSession(form());
    if (!mounted) {
      opened.close();
      return;
    }
    session?.close();
    session = opened;
    final folders = await opened.folders(opened.root);
    final matches = folders
        .where((folder) => folder.name == folderName.text.trim())
        .toList();
    SyncFolder selected;
    if (matches.length > 1) throw const SyncFailure('存在重名目录，请返回修改目录名');
    if (matches.isNotEmpty) {
      selected = matches.single;
    } else {
      if (!mounted) return;
      final confirmed = await showSettingsConfirmDialog(
        context: context,
        title: '新建同步目录',
        message: '没有找到“${folderName.text.trim()}”，是否新建此目录？',
        confirmLabel: '新建',
      );
      if (!confirmed) return;
      selected = await opened.createFolder(opened.root, folderName.text.trim());
    }
    if (mounted) {
      setState(() {
        selection = opened.select(selected);
        step = 3;
      });
    }
  });

  Future<void> save() => run(() async {
    await widget.store.configure({...selection!, 'enabled': 'true'});
    if (mounted) Navigator.pop(context, true);
  });

  Widget field(
    TextEditingController controller,
    String label, {
    bool secret = false,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      key: ValueKey('sync-field-$label'),
      controller: controller,
      enabled: !busy,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final review = step == (manual ? 3 : 2);
    final heading = review
        ? '确认同步设置'
        : step == 0
        ? '登录$title'
        : step == 1
        ? '选择同步目录'
        : '填写 Token';
    return SettingsScaffold(
      title: heading,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  manual ? '登录 → 目录 → Token → 保存' : '登录 → 选择目录 → 保存',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (step == 0) ...[
                  if (!cloud) ...[
                    field(
                      address,
                      '服务器地址',
                      hint: provider == 'webdav'
                          ? 'https://example.com/dav/'
                          : provider == 'smb'
                          ? 'smb://NAS/共享名/'
                          : '$provider://host/',
                    ),
                    field(username, '账号'),
                    field(password, '密码', secret: true),
                    if (provider == 'smb') field(domain, '域（可留空）'),
                    if (provider == 'ftps')
                      SettingsGroupCard(
                        children: [
                          SettingsRow(
                            title: '隐式 FTPS',
                            trailing: SettingsSwitch(
                              value: implicit,
                              onChanged: busy
                                  ? null
                                  : (value) => setState(() => implicit = value),
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: busy ? null : () => run(connect),
                      child: const Text('登录并继续'),
                    ),
                  ] else ...[
                    SettingsGroupCard(
                      children: [
                        SettingsRow(
                          title: title,
                          subtitle: password.text.isEmpty
                              ? '请先登录你的网盘账号'
                              : '已有登录信息，可以继续选择目录',
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: busy ? null : login,
                      child: Text(
                        password.text.isEmpty ? '登录$title' : '重新登录$title',
                      ),
                    ),
                    if (password.text.isNotEmpty)
                      OutlinedButton(
                        onPressed: busy ? null : () => run(connect),
                        child: const Text('使用已有登录继续'),
                      ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => setState(() {
                              manual = true;
                              step = 1;
                              error = null;
                            }),
                      child: const Text('使用已有 Token'),
                    ),
                  ],
                ] else if (step == 1) ...[
                  if (manual && session == null) ...[
                    field(folderName, '同步目录名称'),
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () {
                              try {
                                validateSyncFolderName(folderName.text.trim());
                                setState(() {
                                  step = 2;
                                  error = null;
                                });
                              } on SyncFailure catch (failure) {
                                setState(() => error = failure.message);
                              }
                            },
                      child: const Text('下一步'),
                    ),
                  ] else ...[
                    SettingsGroupCard(
                      children: [
                        SettingsRow(
                          title: '同步目录',
                          subtitle: '选择已有目录或新建目录',
                          onTap: chooseFolder,
                        ),
                      ],
                    ),
                  ],
                ] else if (!review) ...[
                  field(
                    password,
                    provider == 'weiyun' ? 'MCP Token / 官方安装指令' : 'Token',
                    secret: true,
                  ),
                  FilledButton(
                    onPressed: busy ? null : finishToken,
                    child: const Text('验证并继续'),
                  ),
                ] else ...[
                  SettingsGroupCard(
                    children: [
                      SettingsRow(title: '存储服务', value: title),
                      SettingsRow(
                        title: '同步目录',
                        subtitle: selection!['endpoint'],
                        onTap: busy ? null : () => run(chooseFolder),
                      ),
                      const SettingsRow(title: '登录状态', value: '已登录'),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text('将同步书架、阅读与播放进度、已看剧集；不上传正文、视频和登录凭据。'),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: busy ? null : save,
                    child: const Text('保存并启用'),
                  ),
                ],
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:io';
import 'package:flutter/material.dart';
import '../services/platform_channel.dart';
import '../services/sync/multi_device_sync_service.dart';

class MultiDeviceSyncPage extends StatefulWidget {
  const MultiDeviceSyncPage({super.key});
  @override
  State<MultiDeviceSyncPage> createState() => _MultiDeviceSyncPageState();
}

class _MultiDeviceSyncPageState extends State<MultiDeviceSyncPage> {
  final service = MultiDeviceSyncService.instance;
  final endpoint = TextEditingController(),
      username = TextEditingController(),
      password = TextEditingController(),
      domain = TextEditingController();
  String provider = 'webdav';
  bool enabled = false, implicit = false, saving = false, loggingIn = false;
  @override
  void initState() {
    super.initState();
    final c = service.config;
    provider = c['provider'] ?? 'webdav';
    endpoint.text = c['endpoint'] ?? '';
    username.text = c['username'] ?? '';
    password.text = c['password'] ?? '';
    domain.text = c['domain'] ?? '';
    enabled = service.enabled;
    implicit = c['implicit'] == 'true';
  }

  @override
  void dispose() {
    endpoint.dispose();
    username.dispose();
    password.dispose();
    domain.dispose();
    super.dispose();
  }

  void notice(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> save() async {
    setState(() => saving = true);
    try {
      await service.configure({
        'provider': provider,
        'endpoint': endpoint.text.trim(),
        'username': username.text.trim(),
        'password': password.text,
        'domain': domain.text.trim(),
        'implicit': implicit.toString(),
        'enabled': enabled.toString(),
      });
      notice(enabled ? '设置已保存，开始双向同步' : '设置已保存');
    } catch (_) {
      notice('设置保存失败，请重试');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> login() async {
    setState(() => loggingIn = true);
    try {
      final token = await const AppMethodChannel(
        'fqapp/cloud_login',
      ).invokeMethod<String>('login', {'provider': provider});
      if (token != null && token.isNotEmpty) {
        password.text = token;
        notice('已取得登录授权，请保存设置');
      }
    } catch (_) {
      notice('授权尚未完成，可以重新登录或手动导入令牌');
    } finally {
      if (mounted) setState(() => loggingIn = false);
    }
  }

  Widget field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool secret = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: controller,
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
    final selected = SyncProvider.byId(provider);
    final cloud = {
      'ali',
      'weiyun',
      'onedrive',
      'quark',
      'tianyi',
      'mobile139',
    }.contains(provider);
    return Scaffold(
      appBar: AppBar(title: const Text('多端同步')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              '同步在线书架、阅读与播放进度、已看剧集。多台设备使用同一服务和同步文件夹即可，无需注册 fqappX 账号。',
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text('同步文件不含小说正文、视频、本地导入书籍和登录凭据。记录保存在你选择的存储中。'),
            const SizedBox(height: 24),
            DropdownButtonFormField<String>(
              initialValue: provider,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '存储服务',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final p in SyncProvider.values)
                  DropdownMenuItem(
                    value: p.id,
                    child: Text(
                      '${p.title}${p.available ? '' : ' · 尚未开放'}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: saving
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        provider = value;
                        endpoint.clear();
                        username.clear();
                        password.clear();
                        domain.clear();
                        enabled = false;
                        implicit = false;
                      });
                    },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(selected.help),
            ),
            if (selected.available) ...[
              if (provider == 'webdav') ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () {
                      endpoint.text =
                          'https://dav.jianguoyun.com/dav/fqappx-sync-v1/';
                    },
                    child: const Text('填入坚果云 WebDAV 地址'),
                  ),
                ),
              ],
              field(
                endpoint,
                cloud ? '同步文件夹名称' : '同步文件夹地址',
                hint: cloud
                    ? 'fqappx-sync-v1'
                    : provider == 'smb'
                    ? 'smb://NAS/共享名/fqappx-sync-v1/'
                    : provider == 'webdav'
                    ? 'https://example.com/dav/fqappx-sync-v1/'
                    : '$provider://host/fqappx-sync-v1/',
              ),
              if (!cloud) field(username, '账号'),
              if (provider == 'smb') field(domain, '域（可留空）'),
              if (Platform.isAndroid && {'ali', 'onedrive'}.contains(provider))
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: OutlinedButton.icon(
                    onPressed: loggingIn ? null : login,
                    icon: const Icon(Icons.login),
                    label: Text(loggingIn ? '正在授权…' : '登录 ${selected.title}'),
                  ),
                ),
              field(
                password,
                provider == 'webdav'
                    ? '应用密码 / 密码'
                    : provider == 'weiyun'
                    ? 'MCP Token / 官方安装指令'
                    : cloud
                    ? '登录令牌（可手动导入）'
                    : '密码',
                secret: true,
              ),
              if (provider == 'ftps')
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('隐式 FTPS'),
                  subtitle: const Text('默认使用显式 TLS；仅在服务器要求时开启隐式模式。'),
                  value: implicit,
                  onChanged: (v) => setState(() => implicit = v),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用自动同步'),
                subtitle: const Text('新记录自动同步；启动、进入书架及下拉刷新时合并多端记录。'),
                value: enabled,
                onChanged: (v) => setState(() => enabled = v),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: saving ? null : save,
                child: Text(saving ? '保存中…' : '保存设置'),
              ),
            ],
            const SizedBox(height: 24),
            AnimatedBuilder(
              animation: service,
              builder: (context, _) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(service.status),
                      if (service.lastSuccess != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            '最近成功：${service.lastSuccess!.toLocal().toString().split('.').first}',
                          ),
                        ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: service.busy || !service.enabled
                            ? null
                            : service.sync,
                        icon: service.busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.sync),
                        label: const Text('立即同步'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '删除会同步到其他设备。离线设备的旧记录不会恢复已删除项目；之后明确重新加入书架可以恢复。同步文件夹请勿混放其他应用的数据。',
            ),
            const SizedBox(height: 8),
            const Text('每台设备固定保留两个快照，写入后校验，断网时保留本机记录并重试。卸载应用后重新安装会作为新设备加入。'),
          ],
        ),
      ),
    );
  }
}

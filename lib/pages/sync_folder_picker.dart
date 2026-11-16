import 'package:material_ui/material_ui.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../services/sync/sync_setup_session.dart';
import '../services/sync/sync_transport.dart';
import '../widgets/settings/settings_widgets.dart';

class SyncFolderPicker extends StatefulWidget {
  const SyncFolderPicker({super.key, required this.session});
  final SyncSetupSession session;
  @override
  State<SyncFolderPicker> createState() => _SyncFolderPickerState();
}

class _SyncFolderPickerState extends State<SyncFolderPicker> {
  late final stack = [widget.session.root];
  List<SyncFolder> folders = [];
  bool loading = true;
  String? error;
  SyncFolder get current => stack.last;
  bool get canSelect =>
      !loading &&
      error == null &&
      (stack.length > 1 ||
          {
            'webdav',
            'ftp',
            'ftps',
            'smb',
          }.contains(widget.session.config['provider']));

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.session.folders(current);
      if (mounted) setState(() => folders = result);
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = failure is SyncFailure
              ? failure.message
              : '目录读取失败，请检查连接后重试',
        );
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> create() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewFolderDialog(),
    );
    if (name == null || !mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final folder = await widget.session.createFolder(current, name);
      if (!mounted) return;
      stack.add(folder);
      await load();
    } catch (failure) {
      if (mounted) {
        setState(() => loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              failure is SyncFailure ? failure.message : '新建目录失败，请检查权限后重试',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => SettingsScaffold(
    title: '选择同步目录',
    actions: [
      IconButton(
        tooltip: '新建目录',
        onPressed: loading || error != null ? null : create,
        icon: const Icon(LucideIcons.folder_plus),
      ),
    ],
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SettingsGroupCard(
              children: [
                if (stack.length > 1)
                  SettingsRow(
                    title: '上一级',
                    icon: LucideIcons.arrow_up,
                    onTap: loading
                        ? null
                        : () {
                            stack.removeLast();
                            load();
                          },
                  ),
                SettingsRow(
                  title: current.name,
                  subtitle: current.path,
                  icon: LucideIcons.folder,
                ),
              ],
            ),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(error!, textAlign: TextAlign.center),
                        ),
                        TextButton(onPressed: load, child: const Text('重试')),
                      ],
                    ),
                  )
                : folders.isEmpty
                ? const Center(child: Text('此目录下没有文件夹'))
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      SettingsGroupCard(
                        children: [
                          for (final folder in folders)
                            SettingsRow(
                              title: folder.name,
                              icon: LucideIcons.folder,
                              onTap: () {
                                stack.add(folder);
                                load();
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: canSelect
                    ? () => Navigator.pop(context, current)
                    : null,
                child: const Text('使用此目录'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _NewFolderDialog extends StatefulWidget {
  const _NewFolderDialog();
  @override
  State<_NewFolderDialog> createState() => _NewFolderDialogState();
}

class _NewFolderDialogState extends State<_NewFolderDialog> {
  final controller = TextEditingController(text: 'fqappx-sync');
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    try {
      validateSyncFolderName(controller.text.trim());
      Navigator.pop(context, controller.text.trim());
    } on SyncFailure catch (failure) {
      setState(() => error = failure.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新建目录'),
    content: TextField(
      controller: controller,
      autofocus: true,
      decoration: InputDecoration(labelText: '目录名称', errorText: error),
      onSubmitted: (_) => submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: submit, child: const Text('创建')),
    ],
  );
}

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/reminder_template.dart';
import '../storage/secure_store.dart';

/// 提醒模板管理:系统模板只读,自定义模板可新增、编辑、删除。
class ReminderTemplatesPage extends StatefulWidget {
  const ReminderTemplatesPage({super.key});

  @override
  State<ReminderTemplatesPage> createState() => _ReminderTemplatesPageState();
}

class _ReminderTemplatesPageState extends State<ReminderTemplatesPage> {
  late final Future<ApiClient> _api = ApiConfig.client();
  final _store = SecureStore();

  List<ReminderTemplate> _templates = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final list = await (await _api).listReminderTemplates(jwt);
      if (!mounted) return;
      setState(() {
        _templates = list.map(ReminderTemplate.fromJson).toList(growable: false);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  Future<void> _editTemplate([ReminderTemplate? template]) async {
    final isEdit = template != null;
    final nameController = TextEditingController(text: template?.name ?? '');
    final titleController =
        TextEditingController(text: template?.titleTemplate ?? '');
    final bodyController =
        TextEditingController(text: template?.bodyTemplate ?? '');

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isEdit ? '编辑模板' : '新增模板'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: !isEdit,
                decoration: const InputDecoration(
                  labelText: '名称 *',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: titleController,
                decoration: const InputDecoration(
                  labelText: '标题模板',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: bodyController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '正文模板',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('请输入模板名称')));
                return;
              }
              Navigator.of(context).pop(true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final body = {
      'name': nameController.text.trim(),
      'title_template': titleController.text.trim(),
      'body_template': bodyController.text.trim(),
    };
    nameController.dispose();
    titleController.dispose();
    bodyController.dispose();
    if (result != true) return;
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      if (isEdit) {
        await (await _api).updateReminderTemplate(jwt, template.id, body);
      } else {
        await (await _api).createReminderTemplate(jwt, body);
      }
      await _load();
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('保存失败,请检查网络后重试');
    }
  }

  Future<void> _deleteTemplate(ReminderTemplate template) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除模板'),
        content: Text('确定删除模板「${template.name}」吗?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      await (await _api).deleteReminderTemplate(jwt, template.id);
      await _load();
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('删除失败,请检查网络后重试');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('提醒模板')),
      floatingActionButton: FloatingActionButton(
        tooltip: '新增模板',
        onPressed: () => _editTemplate(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _templates.isEmpty
              ? const Center(child: Text('暂无模板,点击右下角 + 新增'))
              : ListView.separated(
                  itemCount: _templates.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final template = _templates[index];
                    final system = template.isPreset;
                    return ListTile(
                      leading: Icon(
                        system
                            ? Icons.verified_outlined
                            : Icons.description_outlined,
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              template.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (system) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                '系统默认',
                                style: TextStyle(fontSize: 11),
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        '${template.titleTemplate ?? ''}'
                        '${template.bodyTemplate == null ? '' : ' / ${template.bodyTemplate}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: system
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '编辑',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _editTemplate(template),
                                ),
                                IconButton(
                                  tooltip: '删除',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _deleteTemplate(template),
                                ),
                              ],
                            ),
                    );
                  },
                ),
    );
  }
}

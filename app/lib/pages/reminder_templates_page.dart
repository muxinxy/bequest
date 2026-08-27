import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/reminder_template.dart';
import '../storage/secure_store.dart';

/// 类型元数据:标签、图标、色块、可用占位符。
class _TypeInfo {
  const _TypeInfo(this.type, this.label, this.icon, this.color, this.hint);
  final String type;
  final String label;
  final IconData icon;
  final Color color;
  final String hint;
}

const _types = [
  _TypeInfo('expiry', '资产到期', Icons.alarm, Colors.orange, '{name} 资产名 · {date} 日期 · {days} 天数'),
  _TypeInfo('escalation', '未登录升级', Icons.warning_amber_rounded, Colors.red, '{days} 未登录天数'),
  _TypeInfo('inheritance', '继承事件', Icons.menu_book_outlined, Colors.teal, '{name} 资产名'),
];

/// 提醒模板管理:按类型分组展示;系统模板只读,自定义模板可增删改(会员专属)。
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

  /// 当前用户 tier(free/member);null 按免费处理。
  String? _tier;

  bool get _isMember => _tier == 'member';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final api = await _api;
      final list = await api.listReminderTemplates(jwt);
      final me = await api.me(jwt);
      final tier = (me['user'] as Map<String, dynamic>?)?['tier'] as String?;
      if (!mounted) return;
      setState(() {
        _templates = list.map(ReminderTemplate.fromJson).toList(growable: false);
        _tier = tier;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  /// 新增/编辑对话框;新增可选 type,编辑时 type 可改(后端 PUT 支持带 type)。
  /// 保存成功才关闭,失败保留输入显示错误。
  Future<void> _editTemplate([ReminderTemplate? template]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _TemplateDialog(
        isEdit: template != null,
        initial: template,
        isMember: _isMember,
        api: _api,
        store: _store,
      ),
    );
    if (saved == true) await _load();
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
    return DefaultTabController(
      length: _types.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('提醒模板'),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              for (final t in _types) Tab(text: t.label),
            ],
          ),
        ),
        // 免费用户隐藏新增按钮。
        floatingActionButton: _isMember
            ? FloatingActionButton(
                tooltip: '新增模板',
                onPressed: () => _editTemplate(),
                child: const Icon(Icons.add),
              )
            : null,
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  // 模板生效说明。
                  Container(
                    width: double.infinity,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: const Text(
                      '系统生成提醒时优先使用你的自定义模板(会员),未设置时用系统预设文案',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        for (final t in _types)
                          _TypeSection(
                            type: t,
                            templates: _templates
                                .where((x) => x.type == t.type)
                                .toList(growable: false),
                            isMember: _isMember,
                            onEdit: _editTemplate,
                            onDelete: _deleteTemplate,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 单个类型分区:预设只读 + 自定义可编辑;空类提示。
class _TypeSection extends StatelessWidget {
  const _TypeSection({
    required this.type,
    required this.templates,
    required this.isMember,
    required this.onEdit,
    required this.onDelete,
  });

  final _TypeInfo type;
  final List<ReminderTemplate> templates;
  final bool isMember;
  final void Function(ReminderTemplate?) onEdit;
  final void Function(ReminderTemplate) onDelete;

  @override
  Widget build(BuildContext context) {
    final custom = templates.where((t) => !t.isPreset).toList();
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // 分区头:类型色块 + 会员专属标签。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: type.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(type.icon, size: 14, color: type.color),
                    const SizedBox(width: 4),
                    Text(
                      type.label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: type.color,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isMember) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '会员专属',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (custom.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                '该类型暂无自定义模板',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          )
        else
          for (final template in custom)
            _templateTile(context, template),
        if (templates.any((t) => t.isPreset)) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '系统预设(只读)',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final template in templates.where((t) => t.isPreset))
            _templateTile(context, template),
        ],
      ],
    );
  }

  Widget _templateTile(BuildContext context, ReminderTemplate template) {
    final system = template.isPreset;
    return ListTile(
      leading: Icon(
        system ? Icons.verified_outlined : Icons.description_outlined,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(template.name, overflow: TextOverflow.ellipsis),
          ),
          if (system) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('系统默认', style: TextStyle(fontSize: 11)),
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
                  onPressed: () => onEdit(template),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => onDelete(template),
                ),
              ],
            ),
    );
  }
}

/// 新增/编辑模板对话框:名称/标题/正文 + type 下拉 + 按类型占位符说明。
/// 弹窗内调 API 保存,成功才 pop(true),失败保留输入显示错误。
class _TemplateDialog extends StatefulWidget {
  const _TemplateDialog({
    required this.isEdit,
    required this.initial,
    required this.isMember,
    required this.api,
    required this.store,
  });

  final bool isEdit;
  final ReminderTemplate? initial;
  final bool isMember;
  final Future<ApiClient> api;
  final SecureStore store;

  @override
  State<_TemplateDialog> createState() => _TemplateDialogState();
}

class _TemplateDialogState extends State<_TemplateDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  late String _type;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    _nameController = TextEditingController(text: t?.name ?? '');
    _titleController = TextEditingController(text: t?.titleTemplate ?? '');
    _bodyController = TextEditingController(text: t?.bodyTemplate ?? '');
    _type = t?.type ?? 'expiry';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  _TypeInfo get _typeInfo =>
      _types.firstWhere((x) => x.type == _type, orElse: () => _types.first);

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入模板名称');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final jwt = await widget.store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final body = {
        'name': name,
        'title_template': _titleController.text.trim(),
        'body_template': _bodyController.text.trim(),
        'type': _type,
      };
      final api = await widget.api;
      if (widget.isEdit) {
        await api.updateReminderTemplate(jwt, widget.initial!.id, body);
      } else {
        await api.createReminderTemplate(jwt, body);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '保存失败,请检查网络后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEdit ? '编辑模板' : '新增模板'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: !widget.isEdit,
              decoration: const InputDecoration(
                labelText: '名称 *',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // type 下拉:新增可选,编辑也可改(后端 PUT 支持带 type)。
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(
                labelText: '类型',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final t in _types)
                  DropdownMenuItem(value: t.type, child: Text(t.label)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _type = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: '标题模板',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _bodyController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '正文模板',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '可用变量:${_typeInfo.hint}',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中...' : '保存'),
        ),
      ],
    );
  }
}

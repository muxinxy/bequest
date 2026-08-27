import 'package:flutter/material.dart';

import '../models/category.dart';
import '../repository/asset_repository.dart';
import '../widgets/text_save_dialog.dart';
import 'category_inheritors_page.dart';

/// 分组管理:列表(含预设与自定义)、新增、改名、删除。
/// 预设分组是服务端按用户预置的真实行,与自定义分组一样可编辑/删除。
class CategoryPage extends StatefulWidget {
  const CategoryPage({super.key, required this.repository});

  final AssetRepository repository;

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<CategoryPage> {
  List<Category> _categories = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.repository.listCategories();
      if (!mounted) return;
      setState(() {
        _categories = list.map(Category.fromJson).toList(growable: false);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  /// 新增/编辑共用的分组对话框;编辑时预填名称。
  /// 弹窗内保存,409/失败保留弹窗与输入,成功才 pop 返回名称。
  Future<String?> _showCategoryDialog({
    String initialName = '',
    String title = '新增分组',
    required Future<void> Function(String name) onSave,
  }) {
    return showDialog<String>(
      context: context,
      builder: (context) => TextSaveDialog(
        title: title,
        labelText: '分组名称',
        initialValue: initialName,
        conflictMessage: '分组已存在',
        onSave: onSave,
      ),
    );
  }

  Future<void> _addCategory() async {
    final name = await _showCategoryDialog(
      onSave: (n) async => widget.repository.createCategory(n),
    );
    if (name == null) return;
    await _load();
  }

  Future<void> _editCategory(Category category) async {
    final name = await _showCategoryDialog(
      initialName: category.name,
      title: '编辑分组',
      onSave: (n) async => widget.repository.updateCategory(category.id, {'name': n}),
    );
    if (name == null) return;
    await _load();
  }

  /// 打开分组的继承人设置页(该分组下所有资产默认按此继承人交接)。
  Future<void> _openInheritors(Category category) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CategoryInheritorsPage(
          categoryId: category.id,
          categoryName: category.name,
          repository: widget.repository,
        ),
      ),
    );
  }

  /// 上移/下移分组(乐观更新,失败回滚重载)。
  Future<void> _move(int index, int delta) async {
    final list = [..._categories];
    final tmp = list[index];
    list[index] = list[index + delta];
    list[index + delta] = tmp;
    setState(() => _categories = list);
    try {
      await widget.repository.reorderCategories(list.map((c) => c.id).toList());
    } catch (_) {
      _showError('排序保存失败,请检查网络后重试');
      await _load();
    }
  }

  /// 删除分组:确认框显示受影响资产数,可选"移入目标分组"(合并/防误删)。
  Future<void> _deleteCategory(Category category) async {
    final others = _categories.where((c) => c.id != category.id).toList();
    String? moveToId; // null = 未分类
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('删除分组'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('「${category.name}」含 ${category.assetCount} 个资产。'),
              const SizedBox(height: 8),
              Text(
                '删除后这些资产将移入所选分组(默认未分组)。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              if (others.isNotEmpty)
                DropdownButtonFormField<String?>(
                  initialValue: null,
                  decoration: const InputDecoration(
                    labelText: '资产移入',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('未分组')),
                    ...others.map(
                      (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ),
                  ],
                  onChanged: (v) => setDialogState(() => moveToId = v),
                )
              else
                Text(
                  '无可移入的分组,资产将变为未分组。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
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
      ),
    );
    if (confirmed != true) return;
    try {
      // moveTo 传分组 id 字符串:云端实现内部转 int64,
      // 本地模式直接用字符串 id(本地 id 为 'L<时间戳><序号>',int 转换会失效)。
      await widget.repository.deleteCategory(category.id, moveTo: moveToId);
      await _load();
    } catch (_) {
      _showError('删除失败,请检查网络后重试');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('分组管理'),
        actions: [
          IconButton(
            tooltip: '添加分组',
            icon: const Icon(Icons.add),
            onPressed: _addCategory,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _categories.isEmpty
          ? const Center(child: Text('暂无分组,点击右上角 + 新增'))
          : ListView.separated(
              itemCount: _categories.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final category = _categories[index];
                return ListTile(
                  leading: Icon(
                    Icons.category_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(category.name),
                  subtitle: Text('${category.assetCount} 个资产'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '上移',
                        icon: const Icon(Icons.arrow_upward),
                        onPressed: index == 0 ? null : () => _move(index, -1),
                      ),
                      IconButton(
                        tooltip: '下移',
                        icon: const Icon(Icons.arrow_downward),
                        onPressed: index == _categories.length - 1
                            ? null
                            : () => _move(index, 1),
                      ),
                      if (category.isPreset)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '预设',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: '设置继承人',
                        icon: const Icon(Icons.people_outline),
                        onPressed: () => _openInheritors(category),
                      ),
                      IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _deleteCategory(category),
                      ),
                    ],
                  ),
                  onTap: () => _editCategory(category),
                );
              },
            ),
    );
  }
}

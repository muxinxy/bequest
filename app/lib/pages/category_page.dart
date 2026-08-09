import 'package:flutter/material.dart';

import '../models/category.dart';
import '../repository/asset_repository.dart';

/// 分类管理:列表(含预设与自定义)、新增、改名/改类型、删除。
/// 预设分类是服务端按用户预置的真实行,与自定义分类一样可编辑/删除。
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  /// 新增/编辑共用的分类对话框;编辑时预填名称与类型。
  /// 返回 (name, assetType) 或 null(取消)。
  Future<(String, String)?> _showCategoryDialog({
    String initialName = '',
    String initialType = 'physical',
    String title = '新增分类',
  }) async {
    final controller = TextEditingController(text: initialName);
    var assetType = initialType;
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: '分类名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'physical',
                      label: Text('实体'),
                      icon: Icon(Icons.inventory_2_outlined),
                    ),
                    ButtonSegment(
                      value: 'virtual',
                      label: Text('虚拟'),
                      icon: Icon(Icons.cloud_outlined),
                    ),
                  ],
                  selected: {assetType},
                  onSelectionChanged: (selection) =>
                      setDialogState(() => assetType = selection.first),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('请输入分类名称')));
                  return;
                }
                Navigator.of(context).pop((value, assetType));
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _addCategory() async {
    final result = await _showCategoryDialog();
    if (result == null) return;
    try {
      await widget.repository.createCategory(result.$1, assetType: result.$2);
      await _load();
    } catch (_) {
      _showError('新增失败,请检查网络后重试');
    }
  }

  Future<void> _editCategory(Category category) async {
    final result = await _showCategoryDialog(
      initialName: category.name,
      initialType: category.assetType,
      title: '编辑分类',
    );
    if (result == null) return;
    try {
      await widget.repository.updateCategory(category.id, {
        'name': result.$1,
        'asset_type': result.$2,
      });
      await _load();
    } catch (_) {
      _showError('保存失败,请检查网络后重试');
    }
  }

  Future<void> _deleteCategory(Category category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('确定删除分类「${category.name}」吗?关联资产将变为未分类。'),
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
      await widget.repository.deleteCategory(category.id);
      await _load();
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
      appBar: AppBar(
        title: const Text('分类管理'),
        actions: [
          IconButton(
            tooltip: '添加分类',
            icon: const Icon(Icons.add),
            onPressed: _addCategory,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _categories.isEmpty
              ? const Center(child: Text('暂无分类,点击右上角 + 新增'))
              : ListView.separated(
                  itemCount: _categories.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final category = _categories[index];
                    final isVirtual = category.assetType == 'virtual';
                    return ListTile(
                      leading: Icon(
                        isVirtual
                            ? Icons.devices_outlined
                            : Icons.home_outlined,
                        color: isVirtual
                            ? Colors.blue
                            : Colors.orange,
                      ),
                      title: Text(category.name),
                      subtitle: Text(isVirtual ? '虚拟' : '实体'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (category.isPreset)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .secondaryContainer,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '预设',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSecondaryContainer,
                                ),
                              ),
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

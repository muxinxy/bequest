import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';

/// 分组(分类)级继承人设置:为该分组绑定一个或多个继承人。
/// 继承触发时,该分组下**未单独绑定继承人**的资产按分组继承人交接。
///
/// 仅云端模式支持(本地模式无继承概念,入口不显示)。
class CategoryInheritorsPage extends StatefulWidget {
  const CategoryInheritorsPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
    required this.repository,
  });

  final String categoryId;
  final String categoryName;
  final AssetRepository repository;

  @override
  State<CategoryInheritorsPage> createState() => _CategoryInheritorsPageState();
}

class _CategoryInheritorsPageState extends State<CategoryInheritorsPage> {
  final _store = SecureStore();

  List<Map<String, dynamic>> _bindings = const [];
  List<Map<String, dynamic>> _inheritors = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      final bindings =
          await widget.repository.listCategoryInheritors(widget.categoryId);
      final inheritors = jwt == null
          ? <Map<String, dynamic>>[]
          : await (await ApiConfig.client()).listInheritors(jwt);
      if (mounted) {
        setState(() {
          _bindings = bindings;
          _inheritors = inheritors;
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
    }
  }

  Future<void> _add() async {
    final boundIds = _bindings.map((b) => '${b['inheritor_id']}').toSet();
    final available = _inheritors
        .where((i) => !boundIds.contains('${i['id']}'))
        .toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无可用继承人(请先在继承人管理中创建)')),
      );
      return;
    }
    var selected = '${available.first['id']}';
    var triggerDays = '0';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('绑定继承人'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: const InputDecoration(labelText: '继承人'),
                items: [
                  for (final i in available)
                    DropdownMenuItem(
                      value: '${i['id']}',
                      child: Text(
                        '${i['name']}${i['email'] == null ? '' : ' (${i['email']})'}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setDialogState(() => selected = v ?? selected),
              ),
              const SizedBox(height: 8),
              TextField(
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '独立触发天数(0 = 沿用全局升级阶梯)',
                  helperText: '号主连续 N 天未登录后触发该分组资产交接',
                ),
                onChanged: (v) => setDialogState(() => triggerDays = v),
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
              child: const Text('绑定'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final days = int.tryParse(triggerDays);
      await widget.repository.createCategoryInheritor(widget.categoryId, {
        'inheritor_id': int.tryParse(selected),
        'priority': _bindings.length + 1,
        'trigger_days': (days == null || days <= 0) ? null : days,
      });
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('绑定失败')));
    }
  }

  Future<void> _remove(Map<String, dynamic> binding) async {
    try {
      await widget.repository.deleteCategoryInheritor(
        widget.categoryId,
        '${binding['id']}',
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('解绑失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('分组继承人 · ${widget.categoryName}')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('绑定继承人'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _bindings.isEmpty
              ? const Center(
                  child: Text(
                    '未设置分组继承人\n该分组下资产继承触发时随全量交接',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: _bindings.length,
                  itemBuilder: (context, index) {
                    final b = _bindings[index];
                    final days = b['trigger_days'];
                    return ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(
                        '${b['inheritor_name'] ?? '继承人 #${b['inheritor_id']}'}',
                      ),
                      subtitle: Text(
                        days == null
                            ? '沿用全局触发阶梯'
                            : '触发:号主 $days 天未登录',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: '解绑',
                        onPressed: () => _remove(b),
                      ),
                    );
                  },
                ),
    );
  }
}

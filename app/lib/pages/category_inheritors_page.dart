import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../l10n/app_l10n.dart';
import '../models/trigger_ladder.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';
import '../widgets/ladder_dropdown.dart';

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
  List<TriggerLadder> _ladders = const [];
  bool _loading = true;

  /// 多选批量修改阶梯模式。
  bool _multiSelect = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      final api = await ApiConfig.client();
      final bindings =
          await widget.repository.listCategoryInheritors(widget.categoryId);
      final inheritors = jwt == null
          ? <Map<String, dynamic>>[]
          : await api.listInheritors(jwt);
      final ladders = jwt == null
          ? <TriggerLadder>[]
          : await loadTriggerLadders(api, jwt);
      if (mounted) {
        setState(() {
          _bindings = bindings;
          _inheritors = inheritors;
          _ladders = ladders;
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L10n.tr('加载失败,请检查网络后重试'))));
    }
  }

  Future<void> _add() async {
    final boundIds = _bindings.map((b) => '${b['inheritor_id']}').toSet();
    final available = _inheritors
        .where((i) => !boundIds.contains('${i['id']}'))
        .toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.tr('暂无可用继承人(请先在继承人管理中创建)'))),
      );
      return;
    }
    var selected = '${available.first['id']}';
    int? ladderId; // null = 全局阶梯
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(L10n.tr('绑定继承人')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selected,
                decoration: InputDecoration(labelText: L10n.tr('继承人')),
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
              LadderDropdown(
                ladders: _ladders,
                value: ladderId,
                onChanged: (v) => setDialogState(() => ladderId = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(L10n.tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(L10n.tr('绑定')),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.repository.createCategoryInheritor(widget.categoryId, {
        'inheritor_id': int.tryParse(selected),
        'priority': _bindings.length + 1,
        'ladder_id': ladderId,
      });
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L10n.tr('绑定失败'))));
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
      ).showSnackBar(SnackBar(content: Text(L10n.tr('解绑失败'))));
    }
  }

  /// 修改单个绑定的触发阶梯。
  Future<void> _changeLadder(Map<String, dynamic> binding) async {
    final (ok, ladderId) = await pickLadderDialog(
      context,
      ladders: _ladders,
      initial: (binding['ladder_id'] as num?)?.toInt(),
    );
    if (!ok || !mounted) return;
    try {
      await widget.repository.updateCategoryInheritorLadder(
        widget.categoryId,
        '${binding['id']}',
        ladderId,
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L10n.tr('修改失败'))));
    }
  }

  /// 多选批量修改所选绑定的触发阶梯。
  Future<void> _changeSelectedLadders() async {
    if (_selected.isEmpty) return;
    final (ok, ladderId) = await pickLadderDialog(
      context,
      ladders: _ladders,
    );
    if (!ok || !mounted) return;
    try {
      for (final id in _selected) {
        await widget.repository.updateCategoryInheritorLadder(
          widget.categoryId,
          id,
          ladderId,
        );
      }
      setState(() {
        _multiSelect = false;
        _selected.clear();
      });
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L10n.tr('修改失败'))));
    }
  }

  /// 绑定行的阶梯展示文本。
  static String _ladderLabel(Map<String, dynamic> b) {
    final name = b['ladder_name']?.toString() ?? '';
    return name.isEmpty ? L10n.tr('阶梯:全局') : L10n.trp('阶梯:{name}', {'name': name});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _multiSelect
              ? L10n.trp('已选 {n} 项', {'n': '${_selected.length}'})
              : L10n.trp('分组继承人 · {name}', {'name': widget.categoryName}),
        ),
        actions: _multiSelect
            ? [
                IconButton(
                  tooltip: L10n.tr('取消'),
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _multiSelect = false;
                    _selected.clear();
                  }),
                ),
              ]
            : [
                IconButton(
                  tooltip: L10n.tr('批量修改阶梯'),
                  icon: const Icon(Icons.edit_note),
                  onPressed: _bindings.isEmpty
                      ? null
                      : () => setState(() => _multiSelect = true),
                ),
              ],
      ),
      floatingActionButton: _multiSelect
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: Text(L10n.tr('绑定继承人')),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _bindings.isEmpty
              ? Center(
                  child: Text(
                    L10n.tr('未设置分组继承人\n该分组下资产继承触发时随全量交接'),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: _bindings.length,
                  itemBuilder: (context, index) {
                    final b = _bindings[index];
                    final id = '${b['id']}';
                    final selected = _selected.contains(id);
                    return ListTile(
                      leading: _multiSelect
                          ? Checkbox(
                              value: selected,
                              onChanged: (v) => setState(() {
                                if (v == true) {
                                  _selected.add(id);
                                } else {
                                  _selected.remove(id);
                                }
                              }),
                            )
                          : const Icon(Icons.person_outline),
                      title: Text(
                        b['inheritor_name'] == null
                            ? L10n.trp('继承人 #{n}', {'n': '${b['inheritor_id']}'})
                            : '${b['inheritor_name']}',
                      ),
                      subtitle: Text(_ladderLabel(b)),
                      onLongPress: _multiSelect
                          ? null
                          : () => setState(() {
                                _multiSelect = true;
                                _selected.add(id);
                              }),
                      onTap: _multiSelect
                          ? () => setState(() {
                                if (!_selected.remove(id)) _selected.add(id);
                              })
                          : null,
                      trailing: _multiSelect
                          ? null
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: L10n.tr('修改阶梯'),
                                  icon: const Icon(Icons.tune),
                                  onPressed: () => _changeLadder(b),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: L10n.tr('解绑'),
                                  onPressed: () => _remove(b),
                                ),
                              ],
                            ),
                    );
                  },
                ),
      bottomNavigationBar: _multiSelect
          ? BottomAppBar(
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _selected.isEmpty ? null : _changeSelectedLadders,
                    icon: const Icon(Icons.tune),
                    label: Text(L10n.tr('修改阶梯')),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}
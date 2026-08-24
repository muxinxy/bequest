import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/trigger_ladder.dart';
import '../storage/secure_store.dart';
import '../widgets/ladder_dropdown.dart';

/// 触发阶梯管理:列表(全局标注不可删)、新增、修改(含全局)、多选删除自定义阶梯。
class TriggerLaddersPage extends StatefulWidget {
  const TriggerLaddersPage({super.key});

  @override
  State<TriggerLaddersPage> createState() => _TriggerLaddersPageState();
}

class _TriggerLaddersPageState extends State<TriggerLaddersPage> {
  final _store = SecureStore();

  List<TriggerLadder> _ladders = const [];
  bool _loading = true;
  bool _multiSelect = false;
  final Set<int> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final ladders = await loadTriggerLadders(await ApiConfig.client(), jwt);
      if (!mounted) return;
      setState(() {
        _ladders = ladders;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加载失败,请检查网络后重试')),
      );
      Navigator.of(context).pop();
    }
  }

  /// 2 档语义标签(一级:系统通知+IM+邮件;二级:一级+短信)。
  static const _dayLabels = ['一级(天)', '二级(天)'];

  /// 新增/修改阶梯对话框(名称 + 固定 2 档天数输入)。
  Future<void> _editLadder({TriggerLadder? ladder}) async {
    final nameController = TextEditingController(text: ladder?.name ?? '');
    final days = ladder?.days ?? const <int>[];
    final dayControllers = [
      for (var i = 0; i < 2; i++)
        TextEditingController(text: i < days.length ? '${days[i]}' : ''),
    ];
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(ladder == null ? '新增阶梯' : '修改阶梯'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                maxLength: 20,
                decoration: const InputDecoration(
                  labelText: '阶梯名称 *',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < 2; i++) ...[
                TextField(
                  controller: dayControllers[i],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _dayLabels[i],
                    border: const OutlineInputBorder(),
                  ),
                ),
                if (i < 1) const SizedBox(height: 8),
              ],
              const SizedBox(height: 4),
              const Text(
                '一级:系统通知+IM+邮件;二级:一级+短信',
                style: TextStyle(fontSize: 12, color: Colors.grey),
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
              final days = <int>[];
              for (final c in dayControllers) {
                final v = int.tryParse(c.text.trim());
                if (v == null || v <= 0 || v > 3650) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('天数需为 1-3650 的正整数')),
                  );
                  return;
                }
                days.add(v);
              }
              for (var i = 1; i < 2; i++) {
                if (days[i] <= days[i - 1]) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('需要 2 个依次递增的正整数(一级:IM+邮件, 二级:一级+短信)'),
                    ),
                  );
                  return;
                }
              }
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入阶梯名称')),
                );
                return;
              }
              Navigator.of(context).pop(true);
              _saveLadder(name: name, days: days, ladder: ladder);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    nameController.dispose();
    for (final c in dayControllers) {
      c.dispose();
    }
    if (result != true) return;
  }

  Future<void> _saveLadder({
    required String name,
    required List<int> days,
    TriggerLadder? ladder,
  }) async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final api = await ApiConfig.client();
      if (ladder == null) {
        await api.createTriggerLadder(jwt, name: name, days: days);
      } else {
        await api.updateTriggerLadder(jwt, '${ladder.id}', name: name, days: days);
      }
      await _load();
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('保存失败,请检查网络后重试');
    }
  }

  /// 多选删除自定义阶梯;删除后引用它的继承自动回退全局。
  Future<void> _deleteSelected() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除阶梯'),
        content: Text(
          '确定删除所选 ${_selected.length} 个阶梯?\n使用这些阶梯的继承将自动变为全局阶梯。',
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
    );
    if (confirmed != true || !mounted) return;
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      await (await ApiConfig.client())
          .deleteTriggerLadders(jwt, _selected.toList());
      setState(() {
        _multiSelect = false;
        _selected.clear();
      });
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
      appBar: AppBar(
        title: Text(_multiSelect ? '已选 ${_selected.length} 项' : '触发阶梯'),
        actions: _multiSelect
            ? [
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _selected.isEmpty ? null : _deleteSelected,
                ),
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _multiSelect = false;
                    _selected.clear();
                  }),
                ),
              ]
            : null,
      ),
      floatingActionButton: _multiSelect
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _editLadder(),
              icon: const Icon(Icons.add),
              label: const Text('新增阶梯'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _ladders.isEmpty
              ? const Center(child: Text('暂无阶梯,点击右下角 + 新增'))
              : ListView.separated(
                  itemCount: _ladders.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final l = _ladders[index];
                    final selected = _selected.contains(l.id);
                    return ListTile(
                      leading: _multiSelect
                          ? Checkbox(
                              value: selected,
                              onChanged: (v) => setState(() {
                                if (v == true) {
                                  _selected.add(l.id);
                                } else {
                                  _selected.remove(l.id);
                                }
                              }),
                            )
                          : Icon(
                              l.isGlobal
                                  ? Icons.public
                                  : Icons.format_list_numbered,
                              color: l.isGlobal
                                  ? Theme.of(context).colorScheme.primary
                                  : null,
                            ),
                      title: Row(
                        children: [
                          Flexible(child: Text(l.name)),
                          if (l.isGlobal) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '全局',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        l.days.length >= 2
                            ? '一级 ${l.days[0]} 天 / 二级 ${l.days[1]} 天'
                            : l.daysLabel,
                      ),
                      onLongPress: l.isGlobal || _multiSelect
                          ? null
                          : () => setState(() {
                                _multiSelect = true;
                                _selected.add(l.id);
                              }),
                      onTap: _multiSelect
                          ? l.isGlobal
                              ? null
                              : () => setState(() {
                                    if (!_selected.remove(l.id)) {
                                      _selected.add(l.id);
                                    }
                                  })
                          : null,
                      trailing: _multiSelect
                          ? null
                          : IconButton(
                              tooltip: '修改',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _editLadder(ladder: l),
                            ),
                    );
                  },
                ),
    );
  }
}
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
  final _searchController = TextEditingController();

  List<TriggerLadder> _ladders = const [];
  bool _loading = true;
  bool _multiSelect = false;
  final Set<int> _selected = {};

  /// 本地分页:每页 20,列表底部"加载更多"。
  static const _pageSize = 20;
  int _visibleCount = _pageSize;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final ladders = await loadTriggerLadders(await ApiConfig.client(), jwt);
      if (!mounted) return;
      setState(() {
        _ladders = ladders;
        _visibleCount = _pageSize;
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
              Text(
                '一级:系统通知+IM+邮件;二级:一级+短信',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('请输入阶梯名称')));
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
        await api.updateTriggerLadder(
          jwt,
          '${ladder.id}',
          name: name,
          days: days,
        );
      }
      await _load();
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('保存失败,请检查网络后重试');
    }
  }

  /// 多选删除自定义阶梯;删除后引用它的继承自动回退全局。
  /// 删除前先统计各阶梯绑定数,确认框提示"删除后使用全局阶梯"。
  Future<void> _deleteSelected() async {
    final jwt = await _store.readJwt();
    if (jwt == null) throw ApiException('未登录');
    final api = await ApiConfig.client();
    // 删除前统计绑定数(供确认框提示)。
    var boundAssets = 0, boundCategories = 0;
    try {
      for (final id in _selected) {
        final b = await api.getLadderBindings(jwt, id);
        boundAssets += (b['assets'] as List? ?? const []).length;
        boundCategories += (b['categories'] as List? ?? const []).length;
      }
    } catch (_) {
      // 统计失败不阻塞删除。
    }
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除阶梯'),
        content: Text(
          '确定删除所选 ${_selected.length} 个阶梯?\n'
          '该阶梯绑定 $boundAssets 个资产、$boundCategories 个分组,删除后它们将使用全局阶梯。',
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
      await api.deleteTriggerLadders(jwt, _selected.toList());
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

  /// 打开绑定管理对话框;解绑成功后刷新列表。
  Future<void> _openBindings(TriggerLadder l) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => _LadderBindingsDialog(ladder: l),
    );
    if (changed == true) await _load();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // 本地过滤(按阶梯名)+ 分页截取。
    // API 未提供 q 参数,本地过滤;规模大时后端加分页搜索。
    final query = _search.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _ladders
        : _ladders.where((l) => l.name.toLowerCase().contains(query)).toList();
    final shown = filtered.take(_visibleCount).toList();
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
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: '搜索阶梯名称',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: _search.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清空',
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _search = '';
                                  _visibleCount = _pageSize;
                                });
                              },
                            ),
                    ),
                    onChanged: (value) => setState(() {
                      _search = value;
                      _visibleCount = _pageSize;
                    }),
                  ),
                ),
                Expanded(
                  child: _ladders.isEmpty
                      ? const Center(child: Text('暂无阶梯,点击右下角 + 新增'))
                      : filtered.isEmpty
                      ? const Center(child: Text('没有匹配的阶梯'))
                      : ListView.separated(
                          itemCount:
                              shown.length +
                              (_visibleCount < filtered.length ? 1 : 0),
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            // 末尾"加载更多"按钮。
                            if (index >= shown.length) {
                              return Center(
                                child: TextButton(
                                  onPressed: () => setState(
                                    () => _visibleCount += _pageSize,
                                  ),
                                  child: const Text('加载更多'),
                                ),
                              );
                            }
                            final l = shown[index];
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
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
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
                                  : Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: '查看绑定',
                                          icon: const Icon(Icons.link),
                                          onPressed: () => _openBindings(l),
                                        ),
                                        IconButton(
                                          tooltip: '修改',
                                          icon: const Icon(Icons.edit_outlined),
                                          onPressed: () =>
                                              _editLadder(ladder: l),
                                        ),
                                      ],
                                    ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

/// 阶梯绑定管理对话框:显示该阶梯绑定的资产/分组 + 继承人,可多选解绑。
/// 全局阶梯显示所有未绑定阶梯(ladder_id IS NULL)的资产/分组。
class _LadderBindingsDialog extends StatefulWidget {
  const _LadderBindingsDialog({required this.ladder});

  final TriggerLadder ladder;

  @override
  State<_LadderBindingsDialog> createState() => _LadderBindingsDialogState();
}

class _LadderBindingsDialogState extends State<_LadderBindingsDialog> {
  final _store = SecureStore();
  bool _loading = true;
  bool _unbinding = false;
  List<Map<String, dynamic>> _assets = const [];
  List<Map<String, dynamic>> _categories = const [];
  // 选中项存绑定行 id(binding_id),解绑按绑定行粒度。
  final Set<int> _selAssets = {};
  final Set<int> _selCategories = {};

  /// 资产状态色标(与 group_detail 一致)。
  static const _statusColors = {
    'active': Colors.green,
    'inactive': Colors.grey,
    'pending': Colors.orange,
    'expired': Colors.red,
  };
  static const _statusLabels = {
    'active': '正常',
    'inactive': '停用',
    'pending': '待处理',
    'expired': '已过期',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final b = await (await ApiConfig.client()).getLadderBindings(
        jwt,
        widget.ladder.id,
      );
      if (!mounted) return;
      setState(() {
        _assets = (b['assets'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _categories = (b['categories'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  Future<void> _unbind() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解绑所选'),
        content: const Text('解绑后该资产/分组使用全局阶梯,确定解绑?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _unbinding = true);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      await (await ApiConfig.client()).unbindLadder(
        jwt,
        ladderId: widget.ladder.id,
        assetBindings: _selAssets.toList(),
        categoryBindings: _selCategories.toList(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      // 后端可能返回 400(如全局阶梯无需解绑),展示其消息。
      if (!mounted) return;
      setState(() => _unbinding = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _unbinding = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('解绑失败,请检查网络后重试')));
    }
  }

  Widget _bindingTile({
    required int id,
    required String name,
    required String inheritorName,
    required bool selected,
    ValueChanged<bool?>? onChanged,
    String status = '',
  }) {
    final color = _statusColors[status];
    return CheckboxListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: selected,
      onChanged: onChanged,
      title: Text(name),
      subtitle: Row(
        children: [
          // 资产状态色标(active/inactive/pending/expired)。
          if (color != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(
              _statusLabels[status] ?? status,
              style: TextStyle(fontSize: 12, color: color),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              '继承人:${inheritorName.isEmpty ? '未指定' : inheritorName}',
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selCount = _selAssets.length + _selCategories.length;
    // 全局阶梯无需解绑:禁用勾选、不显示"解绑所选"。
    final isGlobal = widget.ladder.isGlobal;
    return AlertDialog(
      title: Text('${widget.ladder.name} · 绑定管理'),
      content: SizedBox(
        width: double.maxFinite,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '资产',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (_assets.isEmpty)
                      const Text('暂无绑定资产', style: TextStyle(fontSize: 13))
                    else
                      for (final a in _assets)
                        _bindingTile(
                          id: (a['binding_id'] as num).toInt(),
                          name: a['name']?.toString() ?? '未命名',
                          inheritorName: a['inheritor_name']?.toString() ?? '',
                          status: a['status']?.toString() ?? '',
                          selected: _selAssets.contains(
                            (a['binding_id'] as num).toInt(),
                          ),
                          onChanged: isGlobal
                              ? null
                              : (v) => setState(() {
                                  final id = (a['binding_id'] as num).toInt();
                                  if (v == true) {
                                    _selAssets.add(id);
                                  } else {
                                    _selAssets.remove(id);
                                  }
                                }),
                        ),
                    const Divider(height: 24),
                    const Text(
                      '分组',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (_categories.isEmpty)
                      const Text('暂无绑定分组', style: TextStyle(fontSize: 13))
                    else
                      for (final c in _categories)
                        _bindingTile(
                          id: (c['binding_id'] as num).toInt(),
                          name: c['name']?.toString() ?? '未命名',
                          inheritorName: c['inheritor_name']?.toString() ?? '',
                          selected: _selCategories.contains(
                            (c['binding_id'] as num).toInt(),
                          ),
                          onChanged: isGlobal
                              ? null
                              : (v) => setState(() {
                                  final id = (c['binding_id'] as num).toInt();
                                  if (v == true) {
                                    _selCategories.add(id);
                                  } else {
                                    _selCategories.remove(id);
                                  }
                                }),
                        ),
                    const SizedBox(height: 8),
                    Text(
                      isGlobal ? '全局阶梯无需解绑' : '解绑后该资产/分组使用全局阶梯',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _unbinding ? null : () => Navigator.of(context).pop(false),
          child: const Text('关闭'),
        ),
        if (!isGlobal)
          FilledButton(
            onPressed: selCount == 0 || _unbinding ? null : _unbind,
            child: Text(_unbinding ? '解绑中...' : '解绑所选($selCount)'),
          ),
      ],
    );
  }
}

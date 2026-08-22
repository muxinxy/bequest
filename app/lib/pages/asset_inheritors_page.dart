import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../models/trigger_ladder.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';
import '../widgets/ladder_dropdown.dart';

/// 资产级继承人设置:为单个资产绑定一个或多个继承人(继承触发时仅该资产交接
/// 给指定继承人,领取时只发放该资产的解密密钥),可设独立触发阶梯。
///
/// 仅云端模式支持(本地模式无继承概念,入口不显示)。
class AssetInheritorsPage extends StatefulWidget {
  const AssetInheritorsPage({
    super.key,
    required this.assetId,
    required this.assetName,
    required this.repository,
  });

  final String assetId;
  final String assetName;
  final AssetRepository repository;

  @override
  State<AssetInheritorsPage> createState() => _AssetInheritorsPageState();
}

class _AssetInheritorsPageState extends State<AssetInheritorsPage> {
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
      final bindings = await widget.repository.listAssetInheritors(widget.assetId);
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
      ).showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
    }
  }

  Future<void> _add() async {
    // 未绑定的继承人(去掉已绑定的)。
    final boundIds = _bindings.map((b) => '${b['inheritor_id']}').toSet();
    final available = _inheritors
        .where((i) => !boundIds.contains('${i['id']}'))
        .toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无可用继承人(请先在继承人管理中创建)')));
      return;
    }
    var selected = '${available.first['id']}';
    int? ladderId; // null = 全局阶梯
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
      await widget.repository.createAssetInheritor(widget.assetId, {
        'inheritor_id': int.tryParse(selected),
        'priority': _bindings.length + 1,
        'ladder_id': ladderId,
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
      await widget.repository.deleteAssetInheritor(
        widget.assetId,
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

  /// 修改单个绑定的触发阶梯。
  Future<void> _changeLadder(Map<String, dynamic> binding) async {
    final (ok, ladderId) = await pickLadderDialog(
      context,
      ladders: _ladders,
      initial: (binding['ladder_id'] as num?)?.toInt(),
    );
    if (!ok || !mounted) return;
    try {
      await widget.repository.updateAssetInheritorLadder(
        widget.assetId,
        '${binding['id']}',
        ladderId,
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('修改失败')));
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
        await widget.repository.updateAssetInheritorLadder(
          widget.assetId,
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
      ).showSnackBar(const SnackBar(content: Text('修改失败')));
    }
  }

  /// 绑定行的阶梯展示文本。
  static String _ladderLabel(Map<String, dynamic> b) {
    final name = b['ladder_name']?.toString() ?? '';
    return name.isEmpty ? '阶梯:全局' : '阶梯:$name';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _multiSelect ? '已选 ${_selected.length} 项' : '资产继承人 · ${widget.assetName}',
        ),
        actions: _multiSelect
            ? [
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _multiSelect = false;
                    _selected.clear();
                  }),
                ),
              ]
            : [
                IconButton(
                  tooltip: '批量修改阶梯',
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
              label: const Text('绑定继承人'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _bindings.isEmpty
              ? const Center(
                  child: Text(
                    '未设置继承人\n继承触发时该资产随全量交接',
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
                        '${b['inheritor_name'] ?? '继承人 #${b['inheritor_id']}'}',
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
                                  tooltip: '修改阶梯',
                                  icon: const Icon(Icons.tune),
                                  onPressed: () => _changeLadder(b),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  tooltip: '解绑',
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
                    label: const Text('修改阶梯'),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}
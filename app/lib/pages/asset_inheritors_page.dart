import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';

/// 资产级继承人设置:为单个资产绑定一个或多个继承人(继承触发时仅该资产交接
/// 给指定继承人,领取时只发放该资产的解密密钥),可设独立触发天数。
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
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      final bindings = await widget.repository.listAssetInheritors(widget.assetId);
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
    var triggerDays = '0'; // 0 = 沿用全局阶梯
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
                  helperText: '号主连续 N 天未登录后触发该资产交接',
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
      await widget.repository.createAssetInheritor(widget.assetId, {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('资产继承人 · ${widget.assetName}')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('绑定继承人'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _bindings.isEmpty
              ? const Center(child: Text('未设置继承人\n继承触发时该资产随全量交接', textAlign: TextAlign.center))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: _bindings.length,
                  itemBuilder: (context, index) {
                    final b = _bindings[index];
                    final days = b['trigger_days'];
                    return ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text('${b['inheritor_name'] ?? '继承人 #${b['inheritor_id']}'}'),
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

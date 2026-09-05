import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../l10n/app_l10n.dart';
import '../repository/asset_repository.dart';
import '../repository/local_asset_repository.dart';
import '../repository/offline_asset_repository.dart';
import '../storage/secure_store.dart';
import '../utils/time_format.dart';

/// 回收站:列出软删除的资产与分组,支持恢复、永久删除、清空。
/// 本地模式删除即永久删除(无回收站);离线模式不可访问。
class RecycleBinPage extends StatefulWidget {
  const RecycleBinPage({super.key, required this.repository});

  final AssetRepository repository;

  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;

  bool get _isLocal => widget.repository is LocalAssetRepository;
  bool get _isOffline => widget.repository is OfflineAssetRepository;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 本地/离线模式无回收站数据。
    if (_isLocal || _isOffline) {
      setState(() {
        _items = const [];
        _loading = false;
      });
      return;
    }
    try {
      final jwt = await SecureStore().readJwt();
      if (jwt == null || jwt.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final items = await (await ApiConfig.client()).listRecycleBin(jwt);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.tr('加载失败,请检查网络后重试'))),
      );
    }
  }

  Future<void> _restore(Map<String, dynamic> item) async {
    try {
      final jwt = await SecureStore().readJwt();
      if (jwt == null) return;
      await (await ApiConfig.client()).restoreRecycleItem(
        jwt,
        '${item['kind']}',
        '${item['id']}',
      );
      await _load();
    } catch (_) {
      _showError(L10n.tr('恢复失败,请检查网络后重试'));
    }
  }

  Future<void> _purge(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L10n.tr('永久删除')),
        content: Text(
          L10n.trp('永久删除「{name}」?此操作不可恢复。', {
            'name': '${item['name']}',
          }),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.tr('删除')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final jwt = await SecureStore().readJwt();
      if (jwt == null) return;
      await (await ApiConfig.client()).purgeRecycleItem(
        jwt,
        '${item['kind']}',
        '${item['id']}',
      );
      await _load();
    } catch (_) {
      _showError(L10n.tr('删除失败,请检查网络后重试'));
    }
  }

  Future<void> _empty() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L10n.tr('清空回收站')),
        content: Text(L10n.tr('回收站内所有项目将被永久删除,此操作不可恢复。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.tr('清空')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final jwt = await SecureStore().readJwt();
      if (jwt == null) return;
      await (await ApiConfig.client()).emptyRecycleBin(jwt);
      await _load();
    } catch (_) {
      _showError(L10n.tr('清空失败,请检查网络后重试'));
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
        title: Text(L10n.tr('回收站')),
        actions: [
          if (!_isLocal && !_isOffline && _items.isNotEmpty)
            IconButton(
              tooltip: L10n.tr('清空回收站'),
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _empty,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _isLocal
              ? Center(child: Text(L10n.tr('本地模式删除即永久删除,无回收站')))
              : _isOffline
                  ? Center(child: Text(L10n.tr('离线模式无法访问回收站')))
                  : _items.isEmpty
                      ? Center(child: Text(L10n.tr('回收站为空')))
                      : ListView.separated(
                          itemCount: _items.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) =>
                              _itemTile(_items[index]),
                        ),
    );
  }

  Widget _itemTile(Map<String, dynamic> item) {
    final isAsset = '${item['kind']}' == 'asset';
    final name = '${item['name'] ?? ''}';
    final category = item['category']?.toString();
    final deletedAt = formatServerTime(item['deleted_at']?.toString());
    return ListTile(
      leading: Icon(
        isAsset ? Icons.inventory_2_outlined : Icons.folder_outlined,
      ),
      title: Text(name),
      subtitle: Text(
        isAsset
            ? L10n.trp('原分组:{category} · 删除于 {time}', {
                'category': category ?? L10n.tr('未分组'),
                'time': deletedAt,
              })
            : L10n.trp('删除于 {time}', {'time': deletedAt}),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: L10n.tr('恢复'),
            icon: const Icon(Icons.restore),
            onPressed: () => _restore(item),
          ),
          IconButton(
            tooltip: L10n.tr('永久删除'),
            icon: const Icon(Icons.delete_forever_outlined),
            onPressed: () => _purge(item),
          ),
        ],
      ),
    );
  }
}
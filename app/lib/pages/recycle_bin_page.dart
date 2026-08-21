import 'package:flutter/material.dart';

import '../api/api_config.dart';
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
        const SnackBar(content: Text('加载失败,请检查网络后重试')),
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
      _showError('恢复失败,请检查网络后重试');
    }
  }

  Future<void> _purge(Map<String, dynamic> item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('永久删除'),
        content: Text('永久删除「${item['name']}」?此操作不可恢复。'),
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
      final jwt = await SecureStore().readJwt();
      if (jwt == null) return;
      await (await ApiConfig.client()).purgeRecycleItem(
        jwt,
        '${item['kind']}',
        '${item['id']}',
      );
      await _load();
    } catch (_) {
      _showError('删除失败,请检查网络后重试');
    }
  }

  Future<void> _empty() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空回收站'),
        content: const Text('回收站内所有项目将被永久删除,此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
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
      _showError('清空失败,请检查网络后重试');
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
        title: const Text('回收站'),
        actions: [
          if (!_isLocal && !_isOffline && _items.isNotEmpty)
            IconButton(
              tooltip: '清空回收站',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _empty,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _isLocal
              ? const Center(child: Text('本地模式删除即永久删除,无回收站'))
              : _isOffline
                  ? const Center(child: Text('离线模式无法访问回收站'))
                  : _items.isEmpty
                      ? const Center(child: Text('回收站为空'))
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
            ? '原分组:${category ?? '未分组'} · 删除于 $deletedAt'
            : '删除于 $deletedAt',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '恢复',
            icon: const Icon(Icons.restore),
            onPressed: () => _restore(item),
          ),
          IconButton(
            tooltip: '永久删除',
            icon: const Icon(Icons.delete_forever_outlined),
            onPressed: () => _purge(item),
          ),
        ],
      ),
    );
  }
}
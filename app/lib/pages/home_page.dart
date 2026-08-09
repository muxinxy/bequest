import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../models/asset.dart';
import '../models/category.dart';
import '../models/preset_categories.dart';
import '../storage/secure_store.dart';
import 'app_lock_setup_page.dart';
import 'asset_edit_page.dart';
import 'category_page.dart';
import 'login_page.dart';

/// 主页:按分类过滤展示资产列表,提供分类管理、锁设置与退出登录。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _api = ApiClient();
  final _store = SecureStore();

  List<Asset> _assets = const [];
  List<Category> _categories = const [];
  Map<String, String> _categoryNames = const {};

  /// 过滤值:null = 全部;自定义分类 id;'未分类' 或预设名 → 无分类资产。
  String? _filterCategoryId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) {
        await _logout();
        return;
      }
      // 校验会话并获取用户名;分类与资产用于列表展示。
      await _api.me(jwt);
      final categories = await _api.listCategories(jwt);
      final assets = await _api.listAssets(jwt);
      if (!mounted) return;
      setState(() {
        _categories = categories.map(Category.fromJson).toList(growable: false);
        _categoryNames = {for (final c in _categories) c.id: c.name};
        _assets = assets.map(Asset.fromJson).toList(growable: false);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加载失败,请检查网络后重试')),
      );
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _logout() async {
    await _store.clearAll();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  String _categoryName(Asset asset) {
    final id = asset.categoryId;
    if (id == null || id.isEmpty) return '未分类';
    return _categoryNames[id] ?? '未分类';
  }

  /// 预设分类与'未分类'同属无服务器分类的桶。
  /// (const 不可用:物理/虚拟预设均含'其他',需运行时去重)
  static final _uncategorizedFilters = <String>{
    '未分类',
    ...kPhysicalPresetCategories,
    ...kVirtualPresetCategories,
  };

  List<Asset> get _filteredAssets {
    final filter = _filterCategoryId;
    if (filter == null) return _assets;
    if (_uncategorizedFilters.contains(filter)) {
      return _assets.where((a) => a.categoryId == null).toList();
    }
    return _assets.where((a) => a.categoryId == filter).toList();
  }

  Future<void> _openEditor([Asset? asset]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => AssetEditPage(asset: asset)),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredAssets;
    return Scaffold(
      appBar: AppBar(
        title: const Text('托孤'),
        actions: [
          IconButton(
            tooltip: '分类管理',
            icon: const Icon(Icons.category_outlined),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const CategoryPage()),
              );
              if (mounted) _load();
            },
          ),
          IconButton(
            tooltip: '锁设置',
            icon: const Icon(Icons.lock_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const AppLockSetupPage()),
            ),
          ),
          IconButton(
            tooltip: '退出登录',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        tooltip: '添加资产',
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      const Text('分类筛选', style: TextStyle(color: Colors.grey)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _filterCategoryId ?? '全部',
                          items: _filterItems(),
                          onChanged: (value) => setState(() {
                            _filterCategoryId =
                                (value == null || value == '全部') ? null : value;
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: filtered.isEmpty
                      ? const Center(child: Text('暂无资产,点击右下角 + 添加'))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final asset = filtered[index];
                              return ListTile(
                                leading: Icon(
                                  asset.assetType == 'virtual'
                                      ? Icons.cloud_outlined
                                      : Icons.inventory_2_outlined,
                                ),
                                title: Text(asset.name),
                                subtitle: Text(
                                  '${_categoryName(asset)}'
                                  '${asset.expiryDate == null ? '' : ' · 到期 ${asset.expiryDate}'}',
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _openEditor(asset),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  List<DropdownMenuItem<String>> _filterItems() {
    final presetNames = <String>{
      ...kPhysicalPresetCategories,
      ...kVirtualPresetCategories,
    };
    return [
      const DropdownMenuItem(value: '全部', child: Text('全部')),
      const DropdownMenuItem(value: '未分类', child: Text('未分类')),
      ...presetNames.map((n) => DropdownMenuItem(value: n, child: Text(n))),
      ..._categories.map(
        (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
      ),
    ];
  }
}

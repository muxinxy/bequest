import 'dart:async';
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/asset.dart';
import '../models/asset_filter.dart';
import '../models/category.dart';
import '../models/entitlements.dart';
import '../models/reminder.dart';
import '../repository/asset_repository.dart';
import '../repository/repository_factory.dart';
import '../storage/secure_store.dart';
import '../sync/backup.dart';
import '../main.dart';
import 'asset_edit_page.dart';
import 'login_page.dart';
import 'reminders_page.dart';
import 'settings_page.dart';

/// 主页:按分类过滤展示资产列表,提供分类管理、应用锁与退出登录。
/// 云端模式经 ApiClient 访问后端;本地模式经 LocalAssetRepository 读加密库。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _store = SecureStore();
  final _searchController = TextEditingController();

  AssetRepository? _repo;
  List<Asset> _assets = const [];
  List<Category> _categories = const [];
  Map<String, String> _categoryNames = const {};
  int _unreadReminders = 0;

  /// 过滤值:null = 全部;自定义/预设分类 id;'未分类' → 无分类资产。
  String? _filterCategoryId;
  String _search = '';
  bool _loading = true;
  bool _isLocal = false;
  bool _hasJwt = false;

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
    setState(() => _loading = true);
    var isLocal = false;
    try {
      final jwt = await _store.readJwt();
      final mk = await _store.readMasterKey();
      final mode = await _store.readStorageMode();
      isLocal = mode == 'local';
      if (isLocal) {
        if (mk == null || mk.isEmpty) {
          // 本地模式但无主密钥(理论不可达,本地入口会保证):回登录页。
          await _exitLocal();
          return;
        }
      } else {
        if (jwt == null) {
          await _logout();
          return;
        }
      }
      final repo = await RepositoryFactory.resolve(
        jwt: jwt,
        masterKeyB64: mk ?? '',
      );
      _repo = repo;
      final categories = await repo.listCategories();
      final assets = await repo.listAssets();
      var unread = 0;
      if (!isLocal) {
        // 会话校验与站内提醒仅云端有;ApiClient 走配置的服务器地址。
        final api = await ApiConfig.client();
        await api.me(jwt!);
        final reminders = await api.listReminders(jwt);
        unread = reminders
            .map(Reminder.fromJson)
            .where((r) => r.isUnread)
            .length;
        _refreshLocalVault(jwt, api);
      }
      if (!mounted) return;
      setState(() {
        _categories = categories.map(Category.fromJson).toList(growable: false);
        _categoryNames = {for (final c in _categories) c.id: c.name};
        _assets = assets.map(Asset.fromJson).toList(growable: false);
        _unreadReminders = unread;
        _isLocal = isLocal;
        _hasJwt = !isLocal && jwt != null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // 本地模式读取加密库失败与网络无关,提示语要准确。
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(
        content: Text(isLocal ? '加载失败,本地数据读取异常' : '加载失败,请检查网络后重试'),
      ));
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 后台刷新本地加密快照(登录后数据加载成功时调用),失败不影响主页。
  void _refreshLocalVault(String jwt, ApiClient api) {
    unawaited(() async {
      try {
        final mk = await _store.readMasterKey();
        if (mk == null) return;
        await refreshLocalVault(jwt, api, mk);
      } catch (_) {
        // 本地快照刷新失败可忽略,下次加载再试。
      }
    }());
  }

  Future<void> _logout() async {
    await _store.clearAll();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  /// 本地模式退出:不清空本机数据,仅返回登录页。
  Future<void> _exitLocal() async {
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

  /// 预设分类与'未分类'同为分类表中的真实行,过滤直接按 id 精确匹配。
  List<Asset> get _filteredAssets {
    final maps = filterAssets(
      assets: _assets.map((a) => a.toJson()).toList(growable: false),
      typeFilter: null,
      categoryFilter: _filterCategoryId,
      search: _search,
    );
    return maps.map(Asset.fromJson).toList(growable: false);
  }

  Future<void> _openEditor([Asset? asset]) async {
    final repo = _repo;
    if (repo == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AssetEditPage(asset: asset, repository: repo),
      ),
    );
    if (mounted) _load();
  }

  /// 打开子页面,返回后刷新数据。
  Future<void> _openPage(Widget page) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    if (mounted) _load();
  }

  Widget _tierBadge() {
    final ent = Entitlements.forJwtAndTier(hasJwt: _hasJwt, tier: null);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        ent.label,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredAssets;
    return Scaffold(
      appBar: AppBar(
        title: const Text('托孤'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _tierBadge(),
          ),
          IconButton(
            tooltip: '提醒',
            icon: Badge.count(
              count: _unreadReminders,
              isLabelVisible: _unreadReminders > 0,
              child: const Icon(Icons.notifications_outlined),
            ),
            onPressed: () => _openPage(const RemindersPage()),
          ),
          IconButton(
            tooltip: '锁定',
            icon: const Icon(Icons.lock_outline),
            onPressed: LockGate.lockNow,
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              final repo = _repo;
              if (repo == null) return;
              _openPage(SettingsPage(repository: repo));
            },
          ),
          TextButton(
            onPressed: _isLocal ? _exitLocal : _logout,
            child: Text(_isLocal ? '退出本地模式' : '退出登录'),
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
                      const Text('分类', style: TextStyle(color: Colors.grey)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _filterCategoryId ?? '全部',
                          items: _filterItems(),
                          onChanged: (value) => setState(() {
                            _filterCategoryId = (value == null ||
                                    value == '全部')
                                ? null
                                : value;
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: '搜索资产名称',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: _search.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清空',
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _search = '');
                              },
                            ),
                    ),
                    onChanged: (value) => setState(() => _search = value),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Text(
                            _assets.isEmpty ? '暂无资产,点击右下角 + 添加' : '没有匹配的资产',
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: filtered.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final asset = filtered[index];
                              return ListTile(
                                leading: const Icon(Icons.inventory_2_outlined),
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
    return [
      const DropdownMenuItem(value: '全部', child: Text('全部')),
      const DropdownMenuItem(value: '未分类', child: Text('未分类')),
      ..._categories.map(
        (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
      ),
    ];
  }
}

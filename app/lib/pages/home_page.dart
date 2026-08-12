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

  /// 云端 tier(free/member),来自 GET /api/v1/me;本地模式为 null(访客权益)。
  String? _tier;

  /// 应用锁是否已设置(设置页完成 PIN/图案配置后为 true);未设置则不显示锁定按钮。
  bool _lockEnabled = false;

  /// 折叠的分组 id 集合(分组视图下点击分组标题折叠/展开)。
  final Set<String> _collapsedGroups = {};

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
      final lockEnabled = await _store.readLockEnabled();
      var unread = 0;
      String? tier;
      if (!isLocal) {
        // 会话校验与站内提醒仅云端有;ApiClient 走配置的服务器地址。
        final api = await ApiConfig.client();
        final me = await api.me(jwt!);
        tier = (me['user'] as Map<String, dynamic>?)?['tier'] as String?;
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
        _tier = tier;
        _lockEnabled = lockEnabled;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // JWT 失效/过期(如后台禁用账号):清凭据回登录页,避免卡在错误页。
      if (e.statusCode == 401) {
        await _logout();
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(
        content: Text(isLocal ? '加载失败,本地数据读取异常' : '加载失败,请检查网络后重试'),
      ));
      if (mounted) setState(() => _loading = false);
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
  /// 恢复进入前暂存的标准槽(云端密钥),并清空当前本地账户标记——
  /// 否则登录页的会话恢复会因 mode=='local' + 有主密钥而弹回本地主页。
  Future<void> _exitLocal() async {
    await _store.deactivateLocalProfile();
    await _store.saveStorageMode('cloud');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  /// 预设分类与'未分类'同为分类表中的真实行,过滤直接按 id 精确匹配。
  List<Asset> get _filteredAssets {
    final maps = filterAssets(
      assets: _assets.map((a) => a.toJson()).toList(growable: false),
      typeFilter: null,
      categoryFilter: _filterCategoryId,
      search: _search,
      categoryNames: _categoryNames,
    );
    return maps.map(Asset.fromJson).toList(growable: false);
  }

  /// 分组视图:资产按分组分组。返回 [(分组 id/名称, 分组资产)] 列表,
  /// 含'未分类'组(尾部)。搜索激活时保持分组结构,空分组不显示。
  List<(String, String, List<Asset>)> get _groupedAssets {
    final assets = _filteredAssets;
    final groups = <String, List<Asset>>{};
    for (final a in assets) {
      final id = a.categoryId ?? '';
      groups.putIfAbsent(id, () => []).add(a);
    }
    final result = <(String, String, List<Asset>)>[];
    for (final c in _categories) {
      final list = groups.remove(c.id);
      if (list != null && list.isNotEmpty) {
        result.add((c.id, c.name, list));
      }
    }
    final uncategorized = groups.remove('');
    if (uncategorized != null && uncategorized.isNotEmpty) {
      result.add(('', '未分类', uncategorized));
    }
    // 搜索激活时可能有资产挂在已删除/未知分类下。
    for (final entry in groups.entries) {
      if (entry.value.isNotEmpty) {
        result.add((entry.key, _categoryNames[entry.key] ?? '未分类', entry.value));
      }
    }
    return result;
  }

  Future<void> _openEditor([Asset? asset]) async {
    final repo = _repo;
    if (repo == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AssetEditPage(asset: asset, repository: repo, tier: _tier),
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
    final ent = Entitlements.forJwtAndTier(hasJwt: _hasJwt, tier: _tier);
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
          if (_lockEnabled)
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
                      hintText: '搜索分组或资产名称',
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
                          child: _GroupedAssetList(
                            groups: _groupedAssets,
                            collapsed: _collapsedGroups,
                            onToggle: (id) => setState(() {
                              if (!_collapsedGroups.remove(id)) {
                                _collapsedGroups.add(id);
                              }
                            }),
                            onTapAsset: _openEditor,
                            onOrganizeUncategorized: _organizeUncategorized,
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  /// 未分类批量整理:把未分类资产全部移至目标分组。
  Future<void> _organizeUncategorized() async {
    final targets = _categories;
    if (targets.isEmpty) return;
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('未分类资产移至'),
        children: [
          for (final c in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(c.id),
              child: Text(c.name),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    final ids = _assets
        .where((a) => a.categoryId == null || a.categoryId!.isEmpty)
        .map((a) => a.id)
        .where((i) => i.isNotEmpty)
        .toList();
    if (ids.isEmpty) return;
    final repo = _repo;
    if (repo == null) return;
    try {
      await repo.moveAssets(ids, int.tryParse(target));
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('移动失败,请检查网络后重试')),
      );
    }
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

/// 分组资产列表:分组标题行(可折叠)+ 组内资产。
/// 组标题显示分组名与资产数,点击折叠/展开。
class _GroupedAssetList extends StatelessWidget {
  const _GroupedAssetList({
    required this.groups,
    required this.collapsed,
    required this.onToggle,
    required this.onTapAsset,
    this.onOrganizeUncategorized,
  });

  final List<(String, String, List<Asset>)> groups;
  final Set<String> collapsed;
  final void Function(String groupId) onToggle;
  final void Function(Asset) onTapAsset;

  /// 未分类整理入口(仅未分类分组显示)。
  final VoidCallback? onOrganizeUncategorized;

  /// 资产是否 30 天内到期(日期粒度,本地时区)。
  bool _expiresSoon(Asset a) {
    final d = a.expiryDate;
    if (d == null || d.isEmpty) return false;
    final exp = DateTime.tryParse(d);
    if (exp == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = exp.difference(today).inDays;
    return days >= 0 && days <= 30;
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (final (id, name, assets) in groups) {
      final isCollapsed = collapsed.contains(id);
      final hasExpirySoon = assets.any(_expiresSoon);
      children.add(
        InkWell(
          onTap: () => onToggle(id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(
                  isCollapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 20,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (hasExpirySoon)
                  Tooltip(
                    message: '有资产 30 天内到期',
                    child: Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: Colors.orange.shade700,
                    ),
                  ),
                const SizedBox(width: 6),
                Text(
                  '${assets.length}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                // 未分类整理:全部移至目标分组。
                if (id == '' && assets.isNotEmpty && onOrganizeUncategorized != null)
                  InkWell(
                    onTap: onOrganizeUncategorized,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Tooltip(
                        message: '未分类资产移至分组',
                        child: Icon(
                          Icons.drive_file_move_outline,
                          size: 18,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      if (!isCollapsed) {
        for (final asset in assets) {
          children.add(
            ListTile(
              contentPadding: const EdgeInsets.only(left: 40, right: 16),
              leading: const Icon(Icons.inventory_2_outlined, size: 20),
              title: Text(asset.name),
              subtitle: asset.expiryDate == null
                  ? null
                  : Text('到期 ${asset.expiryDate}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onTapAsset(asset),
            ),
          );
        }
      }
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: children,
    );
  }
}

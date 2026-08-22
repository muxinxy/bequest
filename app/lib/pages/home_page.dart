import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/asset.dart';
import '../models/category.dart';
import '../models/entitlements.dart';
import '../models/reminder.dart';
import '../models/trigger_ladder.dart';
import '../repository/asset_repository.dart';
import '../repository/offline_asset_repository.dart';
import '../repository/repository_factory.dart';
import '../storage/secure_store.dart';
import '../sync/backup.dart';
import '../main.dart';
import '../widgets/ladder_dropdown.dart';
import 'asset_edit_page.dart';
import 'group_detail_page.dart';
import 'login_page.dart';
import 'recycle_bin_page.dart';
import 'reminders_page.dart';
import 'settings_page.dart';

/// 主页:分组列表视图。每个分组卡片显示名称与资产数量,
/// 支持搜索(分组名)、排序(名称/数量/创建时间)、长按多选删除;
/// 点击分组进入分组详情页。保留离线横幅、提醒/回收站/锁定/设置/退出入口。
/// 云端模式经 ApiClient 访问后端;本地模式经 LocalAssetRepository 读加密库。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

/// 分组排序方式。
enum _GroupSort { name, count, created }

class _HomePageState extends State<HomePage> {
  final _store = SecureStore();
  final _searchController = TextEditingController();

  AssetRepository? _repo;
  List<Asset> _assets = const [];
  List<Category> _categories = const [];
  int _unreadReminders = 0;

  String _search = '';
  _GroupSort _sort = _GroupSort.name;
  bool _loading = true;
  bool _isLocal = false;
  bool _hasJwt = false;

  /// 离线模式:服务器不可达时加载本地缓存(仅可查看/导出)。
  bool _offlineMode = false;

  /// 检测网络恢复的定时器:离线加载后启动,网络恢复时自动静默刷新。
  Timer? _offlineRecoveryTimer;

  /// 离线模式手动刷新中的 loading 状态。
  bool _refreshing = false;

  /// 云端 tier(free/member),来自 GET /api/v1/me;本地模式为 null(访客权益)。
  String? _tier;

  /// 应用锁是否已设置(设置页完成 PIN/图案配置后为 true);未设置则不显示锁定按钮。
  bool _lockEnabled = false;

  /// 分组多选:长按进入多选模式,可批量删除分组。
  bool _multiSelect = false;
  final Set<String> _selectedGroupIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _offlineRecoveryTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    var isLocal = false;
    String? mk;
    try {
      final jwt = await _store.readJwt();
      mk = await _store.readMasterKey();
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
      // 云端网络失败(非认证):尝试离线缓存,服务器恢复前可查看/导出。
      if (!isLocal && await _loadFromOfflineCache(mk ?? '')) {
        if (!mounted) return;
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('服务器连接失败,已加载本地缓存(仅可查看/导出)')),
        );
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(
        content: Text(isLocal ? '加载失败,本地数据读取异常' : '加载失败,请检查网络后重试'),
      ));
      setState(() => _loading = false);
    } catch (_) {
      if (!mounted) return;
      // 云端网络异常:尝试离线缓存。
      if (!isLocal && await _loadFromOfflineCache(mk ?? '')) {
        if (!mounted) return;
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('服务器连接失败,已加载本地缓存(仅可查看/导出)')),
        );
        return;
      }
      if (!mounted) return;
      // 本地模式读取加密库失败与网络无关,提示语要准确。
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(
        content: Text(isLocal ? '加载失败,本地数据读取异常' : '加载失败,请检查网络后重试'),
      ));
      setState(() => _loading = false);
    }
  }

  /// 云端不可用时从本地缓存快照恢复资产/分类(仅离线查看/导出)。
  /// 返回是否成功加载到缓存。
  Future<bool> _loadFromOfflineCache(String masterKeyB64) async {
    try {
      final repo = OfflineAssetRepository(masterKeyB64: masterKeyB64);
      // 有缓存数据(非空资产或分类)才视为可用。
      final assets = (await repo.listAssets()).map(Asset.fromJson).toList();
      final categories =
          (await repo.listCategories()).map(Category.fromJson).toList();
      if (assets.isEmpty && categories.isEmpty) return false;
      if (!mounted) return false;
      setState(() {
        _repo = repo;
        _categories = categories;
        _assets = assets;
        _unreadReminders = 0;
        _isLocal = false;
        _hasJwt = false;
        _offlineMode = true;
        _loading = false;
      });
      // 启动网络恢复检测:10s 周期,恢复后自动静默刷新。
      _startOfflineRecoveryCheck();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 离线加载成功后启动后台恢复检测:每 10s 检查服务器是否可达,
  /// 可达则静默重新加载最新数据并提示用户。
  void _startOfflineRecoveryCheck() {
    _offlineRecoveryTimer?.cancel();
    _offlineRecoveryTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) async {
        if (!mounted || !_offlineMode) {
          _offlineRecoveryTimer?.cancel();
          return;
        }
        try {
          // 快速探测服务器可达性(3s 超时)。
          final api = await ApiConfig.client();
          final jwt = await _store.readJwt();
          if (jwt == null || jwt.isEmpty) return;
          await api.me(jwt).timeout(const Duration(seconds: 3));
          // 服务器恢复:静默刷新数据。
          if (!mounted) return;
          _offlineRecoveryTimer?.cancel();
          _offlineMode = false;
          _refreshLocalVault(jwt, api);
          // 重新加载完整数据(云端仓库)。
          final repo = await RepositoryFactory.resolve(
            jwt: jwt,
            masterKeyB64: await _store.readMasterKey() ?? '',
          );
          if (!mounted) return;
          _repo = repo;
          final categories = (await repo.listCategories())
              .map(Category.fromJson)
              .toList(growable: false);
          final assets = (await repo.listAssets())
              .map(Asset.fromJson)
              .toList(growable: false);
          setState(() {
            _categories = categories;
            _assets = assets;
            _loading = false;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('服务器已恢复,数据已更新为最新')),
            );
          }
        } catch (_) {
          // 服务器仍不可达,继续等待。
        }
      },
    );
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

  /// 手动刷新:离线模式下用户点击"刷新"按钮,尝试重新加载云端最新数据。
  Future<void> _attemptRefreshFromOffline() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    _offlineMode = false;
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) {
        _offlineMode = true;
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未登录,无法刷新')),
        );
        return;
      }
      final mk = await _store.readMasterKey() ?? '';
      final repo = await RepositoryFactory.resolve(jwt: jwt, masterKeyB64: mk);
      final api = await ApiConfig.client();
      final me = await api.me(jwt);
      final tier =
          (me['user'] as Map<String, dynamic>?)?['tier'] as String?;
      final reminders = await api.listReminders(jwt);
      final unread = reminders
          .map(Reminder.fromJson)
          .where((r) => r.isUnread)
          .length;
      final categories = (await repo.listCategories())
          .map(Category.fromJson)
          .toList(growable: false);
      final assets = (await repo.listAssets())
          .map(Asset.fromJson)
          .toList(growable: false);
      _refreshLocalVault(jwt, api);
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _assets = assets;
        _unreadReminders = unread;
        _tier = tier;
        _offlineMode = false;
        _refreshing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('数据已刷新为最新')),
      );
    } catch (_) {
      _offlineMode = true;
      if (!mounted) return;
      setState(() => _refreshing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('刷新失败,服务器仍不可达')),
      );
    }
  }

  /// 退出登录:询问是否一并清除本机加密密钥。
  /// - 保留密钥(默认):同设备下次登录免恢复,可离线解密本地数据;
  /// - 清除密钥:公共电脑/彻底退出,下次登录需重新恢复密钥。
  Future<void> _logout() async {
    final keep = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('是否保留本机加密密钥?\n\n保留:下次登录免恢复,本机加密数据仍可离线读取。\n清除:适用于公共电脑,下次登录需重新恢复密钥。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保留密钥'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('清除密钥'),
          ),
        ],
      ),
    );
    if (keep == null || !mounted) return; // 取消 = 不退出。
    await _store.clearAll(keepKeys: keep);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  /// 本地模式退出:不清空本机数据,仅返回登录页。
  /// 恢复进入前暂存的标准槽(云端密钥),并清空当前本地账户标记——
  /// 否则登录页的会话恢复会因 mode=='local' + 有主密钥而弹回本地主页。
  /// 同时清除应用锁:本地模式退出 = 回到未登录状态,不应再被锁屏拦截。
  Future<void> _exitLocal() async {
    await _store.deactivateLocalProfile();
    await _store.saveStorageMode('cloud');
    await _store.clearAppLock();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  /// 分组列表:(id, 名称, 资产数)。资产数按当前资产列表本地统计
  /// (云端/本地/离线一致),未分组 = category_id 为空的资产数。
  /// 支持搜索(分组名)与排序(名称/数量/创建时间),未分组固定排最后。
  List<(String, String, int)> get _groups {
    final counts = <String, int>{};
    var uncategorized = 0;
    for (final a in _assets) {
      final cid = a.categoryId;
      if (cid == null || cid.isEmpty) {
        uncategorized++;
      } else {
        counts[cid] = (counts[cid] ?? 0) + 1;
      }
    }
    final groups = <(String, String, int, String?)>[
      for (final c in _categories) (c.id, c.name, counts[c.id] ?? 0, c.createdAt),
      ('', '未分组', uncategorized, null),
    ];
    final query = _search.trim().toLowerCase();
    final filtered = query.isEmpty
        ? groups
        : groups.where((g) => g.$2.toLowerCase().contains(query)).toList();
    switch (_sort) {
      case _GroupSort.name:
        filtered.sort((a, b) => a.$2.compareTo(b.$2));
      case _GroupSort.count:
        filtered.sort((a, b) => b.$3.compareTo(a.$3));
      case _GroupSort.created:
        filtered.sort((a, b) => (b.$4 ?? '').compareTo(a.$4 ?? ''));
    }
    // 未分组固定最后。
    final rest = filtered.where((g) => g.$1.isNotEmpty).toList();
    final uncat = filtered.where((g) => g.$1.isEmpty).toList();
    return [...rest, ...uncat].map((g) => (g.$1, g.$2, g.$3)).toList();
  }

  /// 打开分组详情页;返回后刷新(分组内可能发生增删改)。
  Future<void> _openGroup(String id) async {
    final repo = _repo;
    if (repo == null) return;
    final category = id.isEmpty
        ? null
        : _categories.where((c) => c.id == id).firstOrNull;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GroupDetailPage(
          category: category,
          repository: repo,
          tier: _tier,
        ),
      ),
    );
    if (mounted) _load();
  }

  /// 右下角 + 菜单:新增资产(默认未分组)或新增分组。
  Future<void> _fabMenu() async {
    final repo = _repo;
    if (repo == null) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('新增'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('asset'),
            child: const ListTile(
              leading: Icon(Icons.inventory_2_outlined),
              title: Text('新增资产'),
              subtitle: Text('默认未分组'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('group'),
            child: const ListTile(
              leading: Icon(Icons.create_new_folder_outlined),
              title: Text('新增分组'),
            ),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'asset') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AssetEditPage(
            repository: repo,
            tier: _tier,
            initialCategoryId: null,
          ),
        ),
      );
      if (mounted) _load();
    } else {
      await _addGroup();
    }
  }

  /// 新增分组:输入名称创建,创建后刷新列表。
  Future<void> _addGroup() async {
    final repo = _repo;
    if (repo == null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(
            labelText: '分组名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入分组名称')),
                );
                return;
              }
              Navigator.of(context).pop(value);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await repo.createCategory(name);
      if (mounted) _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('新增分组失败,请检查网络后重试')),
      );
    }
  }

  /// 多选删除分组:先把分组内资产移入未分组,再软删分组。
  /// 后端软删分组不会改资产 category_id——不移除会让资产"消失"
  /// (原分组已排除、未分组也查不到),故前端先 moveAssets 再删。
  Future<void> _deleteSelectedGroups() async {    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除分组'),
        content: Text(
          '确定删除所选 ${_selectedGroupIds.length} 个分组?分组内资产将变为未分组。',
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
    final repo = _repo;
    if (repo == null) return;
    try {
      // 先把各分组下资产移到未分组(category_id = null)。
      for (final id in _selectedGroupIds) {
        final ids = [
          for (final a in _assets)
            if (a.categoryId == id) a.id,
        ];
        if (ids.isNotEmpty) await repo.moveAssets(ids, null);
      }
      for (final id in _selectedGroupIds) {
        await repo.deleteCategory(id);
      }
      setState(() {
        _multiSelect = false;
        _selectedGroupIds.clear();
      });
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败,请检查网络后重试')),
      );
    }
  }

  /// 多选统一设置继承人:勾选多名继承人,批量绑定到所有选中分组。
  Future<void> _setSelectedGroupInheritors() async {
    final repo = _repo;
    if (repo == null) return;
    final jwt = await SecureStore().readJwt();
    if (jwt == null || jwt.isEmpty) {
      _showSnack('未登录,无法设置继承人');
      return;
    }
    List<Map<String, dynamic>> inheritors;
    List<TriggerLadder> ladders;
    try {
      final api = await ApiConfig.client();
      inheritors = await api.listInheritors(jwt);
      ladders = await loadTriggerLadders(api, jwt);
    } catch (_) {
      // 断网:回退读缓存继承人(仅可查看列表,绑定需联网)。
      try {
        final mk = await _store.readMasterKey() ?? '';
        inheritors = await OfflineAssetRepository(
          masterKeyB64: mk,
        ).listInheritors();
        ladders = const [];
        _showSnack('离线,显示缓存继承人(绑定需联网)');
      } catch (_) {
        _showSnack('加载继承人失败,请检查网络后重试');
        return;
      }
    }
    if (inheritors.isEmpty) {
      _showSnack('暂无继承人,请先在设置中创建');
      return;
    }
    // 过滤出真实分组(跳过未分组 id='')。
    final groupIds = _selectedGroupIds.where((id) => id.isNotEmpty).toList();
    if (groupIds.isEmpty) return;
    final selected = <String>{};
    int? ladderId; // null = 全局阶梯
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('设置继承人'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 300),
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final i in inheritors)
                        CheckboxListTile(
                          value: selected.contains('${i['id']}'),
                          onChanged: (v) => setDialogState(() {
                            if (v == true) {
                              selected.add('${i['id']}');
                            } else {
                              selected.remove('${i['id']}');
                            }
                          }),
                          title: Text('${i['name']}'),
                          subtitle: Text(
                            '${i['email'] == null || (i['email'] as String).isEmpty ? '' : '${i['email']} · '}'
                            '${i['category_count'] ?? 0} 个分组 · ${i['asset_count'] ?? 0} 个资产',
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              LadderDropdown(
                ladders: ladders,
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
    if (selected.isEmpty) {
      _showSnack('请至少选择一名继承人');
      return;
    }
    try {
      // 每个选中分组 × 每个选中继承人批量绑定,统一应用所选阶梯。
      for (final id in groupIds) {
        for (final iid in selected) {
          await repo.createCategoryInheritor(id, {
            'inheritor_id': int.tryParse(iid),
            'priority': 1,
            'ladder_id': ladderId,
          });
        }
      }
    } catch (_) {
      _showSnack('绑定失败');
      return;
    }
    if (!mounted) return;
    setState(() {
      _multiSelect = false;
      _selectedGroupIds.clear();
    });
    // 刷新分组列表,让继承人名字立即更新。
    await _load();
    _showSnack('已为 ${groupIds.length} 个分组设置 ${selected.length} 名继承人');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
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
    final groups = _groups;
    return Scaffold(
      appBar: AppBar(
        title: _multiSelect
            ? Text('已选 ${_selectedGroupIds.length} 项')
            : const Text('托孤'),
        actions: _multiSelect
            ? [
                IconButton(
                  tooltip: '设置继承人',
                  icon: const Icon(Icons.family_restroom),
                  onPressed: _selectedGroupIds.isEmpty
                      ? null
                      : _setSelectedGroupInheritors,
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _selectedGroupIds.isEmpty
                      ? null
                      : _deleteSelectedGroups,
                ),
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _multiSelect = false;
                    _selectedGroupIds.clear();
                  }),
                ),
              ]
            : [
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
                  tooltip: '回收站',
                  icon: const Icon(Icons.restore_from_trash),
                  onPressed: () {
                    final repo = _repo;
                    if (repo == null) return;
                    _openPage(RecycleBinPage(repository: repo));
                  },
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
      floatingActionButton: _offlineMode || _multiSelect
          ? null // 离线只读 / 多选模式:不提供添加入口。
          : FloatingActionButton(
              tooltip: '添加',
              onPressed: _fabMenu,
              child: const Icon(Icons.add),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_offlineMode)
                  Container(
                    width: double.infinity,
                    color: Colors.orange.shade50,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '离线模式:服务器不可达,已加载本地缓存,仅可查看与导出',
                            style: TextStyle(fontSize: 12, color: Colors.orange),
                          ),
                        ),
                        TextButton(
                          onPressed: () => _attemptRefreshFromOffline(),
                          child: const Text('刷新'),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: '搜索分组名称',
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
                      IconButton(
                        tooltip: '排序',
                        icon: const Icon(Icons.sort),
                        onPressed: () => _pickSort(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: groups.isEmpty
                      ? Center(
                          child: Text(
                            _categories.isEmpty && _assets.isEmpty
                                ? '暂无分组,点击右下角 + 新增资产'
                                : '没有匹配的分组',
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 88),
                            itemCount: groups.length,
                            itemBuilder: (context, index) =>
                                _groupCard(groups[index]),
                          ),
                        ),
                ),
              ],
            ),
    );
  }

  /// 排序菜单:按名称 / 数量 / 创建时间。
  Future<void> _pickSort() async {
    final choice = await showDialog<_GroupSort>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('分组排序'),
        children: [
          _sortOption(_GroupSort.name, '按名称', '名称'),
          _sortOption(_GroupSort.count, '按数量', '数量'),
          _sortOption(_GroupSort.created, '按创建时间', '创建时间'),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _sort = choice);
  }

  Widget _sortOption(_GroupSort value, String label, String currentLabel) {
    return SimpleDialogOption(
      onPressed: () => Navigator.of(context).pop(value),
      child: Row(
        children: [
          Icon(
            _sort == value ? Icons.radio_button_checked : Icons.radio_button_off,
            color: _sort == value ? Theme.of(context).colorScheme.primary : null,
          ),
          const SizedBox(width: 12),
          Text(label),
          if (_sort == value) ...[
            const Spacer(),
            Text(currentLabel, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ],
      ),
    );
  }

  Widget _groupCard((String, String, int) group) {
    final (id, name, count) = group;
    final selected = _selectedGroupIds.contains(id);
    // 未分组是特殊分组:不可删除、不可多选(无长按入口,多选态点击也不选中)。
    final isUngrouped = id.isEmpty;
    // 分组绑定的继承人名字(服务端 inheritor_names;未分组/本地模式为空)。
    final inheritors = isUngrouped
        ? const <String>[]
        : _categories.where((c) => c.id == id).firstOrNull?.inheritorNames ??
              const <String>[];
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onLongPress: _offlineMode || isUngrouped
            ? null
            : () => setState(() {
                  _multiSelect = true;
                  _selectedGroupIds.add(id);
                }),
        onTap: _multiSelect
            ? isUngrouped
                ? null
                : () => setState(() {
                      if (!_selectedGroupIds.remove(id)) {
                        _selectedGroupIds.add(id);
                      }
                    })
            : () => _openGroup(id),
        child: ListTile(
          leading: Icon(
            id.isEmpty ? Icons.folder_off_outlined : Icons.folder_outlined,
            color: Theme.of(context).colorScheme.primary,
          ),
          title: Text(name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$count 个资产'),
              if (inheritors.isNotEmpty)
                Text(
                  '继承人:${inheritors.join('、')}',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
          trailing: _multiSelect
              ? Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  color: selected ? Theme.of(context).colorScheme.primary : null,
                )
              : const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}
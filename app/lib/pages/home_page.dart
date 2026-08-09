import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/asset.dart';
import '../models/category.dart';
import '../models/entitlements.dart';
import '../models/preset_categories.dart';
import '../models/reminder.dart';
import '../repository/asset_repository.dart';
import '../repository/repository_factory.dart';
import '../storage/secure_store.dart';
import '../sync/backup.dart';
import 'app_lock_setup_page.dart';
import 'asset_edit_page.dart';
import 'audit_page.dart';
import 'category_page.dart';
import 'export_page.dart';
import 'import_page.dart';
import 'inheritance_status_page.dart';
import 'inheritors_page.dart';
import 'login_page.dart';
import 'reminder_templates_page.dart';
import 'reminders_page.dart';
import 'server_settings_page.dart';
import 'smtp_settings_page.dart';
import 'sync_settings_page.dart';

/// 主页:按分类过滤展示资产列表,提供分类管理、锁设置与退出登录。
/// 云端模式经 ApiClient 访问后端;本地模式经 LocalAssetRepository 读加密库。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _store = SecureStore();

  AssetRepository? _repo;
  List<Asset> _assets = const [];
  List<Category> _categories = const [];
  Map<String, String> _categoryNames = const {};
  int _unreadReminders = 0;

  /// 过滤值:null = 全部;自定义分类 id;'未分类' 或预设名 → 无分类资产。
  String? _filterCategoryId;
  bool _loading = true;
  bool _isLocal = false;
  bool _hasJwt = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final jwt = await _store.readJwt();
      final mk = await _store.readMasterKey();
      final mode = await _store.readStorageMode();
      final isLocal = mode == 'local';
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
      final repo =
          await RepositoryFactory.resolve(jwt: jwt, masterKeyB64: mk ?? '');
      _repo = repo;
      final categories = await repo.listCategories();
      final assets = await repo.listAssets();
      var unread = 0;
      if (!isLocal) {
        // 会话校验与站内提醒仅云端有;ApiClient 走配置的服务器地址。
        final api = await ApiConfig.client();
        await api.me(jwt!);
        final reminders = await api.listReminders(jwt);
        unread =
            reminders.map(Reminder.fromJson).where((r) => r.isUnread).length;
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加载失败,请检查网络后重试')),
      );
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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
    if (mounted) _load();
  }

  /// 导出流程:先选范围,再交给导出页(验证主密码 + 解密 + 分享)。
  Future<void> _exportFlow() async {
    final repo = _repo;
    if (repo == null) return;
    if (_assets.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂无资产可导出')));
      return;
    }
    final scope = await showDialog<String>(
      context: context,
      builder: (context) => _ExportScopeDialog(hasFilter: _filterCategoryId != null),
    );
    if (scope == null) return;
    final assets = scope == 'filter' ? _filteredAssets : _assets;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ExportPage(assets: assets, repository: repo),
      ),
    );
    if (mounted) _load();
  }

  /// 导入流程:选 JSON 文件后交给导入页(验证主密码 + 逐条创建)。
  Future<void> _importFlow() async {
    final repo = _repo;
    if (repo == null) return;
    // 用官方 file_selector(无自定义 Gradle 插件,CI 可编译;file_picker 有 KGP 兼容问题)。
    const typeGroup = XTypeGroup(label: 'JSON 文件', extensions: ['json']);
    try {
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      if (file == null) return;
      final text = await file.readAsString();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImportPage(fileText: text, repository: repo),
        ),
      );
      // 导入完成后刷新资产列表。
      if (mounted) _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('读取文件失败')));
    }
  }

  void _onMenuSelected(String value) {
    switch (value) {
      case 'inheritors':
        _openPage(const InheritorsPage());
      case 'templates':
        _openPage(const ReminderTemplatesPage());
      case 'categories':
        final repo = _repo;
        if (repo == null) return;
        _openPage(CategoryPage(repository: repo));
      case 'status':
        _openPage(const InheritanceStatusPage());
      case 'export':
        _exportFlow();
      case 'import':
        _importFlow();
      case 'audit':
        _openPage(const AuditPage());
      case 'sync':
        _openPage(const SyncSettingsPage());
      case 'smtp':
        _openPage(const SmtpSettingsPage());
      case 'server':
        _openPage(const ServerSettingsPage());
      case 'mode':
        _openPage(const ServerSettingsPage());
      case 'lock':
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const AppLockSetupPage()),
        );
      case 'logout':
        if (_isLocal) {
          _exitLocal();
        } else {
          _logout();
        }
    }
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
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: (value) => _onMenuSelected(value),
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'inheritors', child: Text('继承人管理')),
              const PopupMenuItem(value: 'templates', child: Text('提醒模板')),
              const PopupMenuItem(value: 'categories', child: Text('分类管理')),
              const PopupMenuItem(value: 'status', child: Text('继承状态')),
              const PopupMenuItem(value: 'export', child: Text('导出资产')),
              const PopupMenuItem(value: 'import', child: Text('导入资产')),
              const PopupMenuItem(value: 'audit', child: Text('审计日志')),
              const PopupMenuItem(value: 'sync', child: Text('同步设置')),
              const PopupMenuItem(value: 'smtp', child: Text('邮箱发件设置')),
              const PopupMenuItem(value: 'server', child: Text('服务器设置')),
              const PopupMenuItem(value: 'mode', child: Text('本地/云端模式切换')),
              const PopupMenuItem(value: 'lock', child: Text('锁设置')),
              PopupMenuItem(
                value: 'logout',
                child: Text(_isLocal ? '退出本地模式' : '退出登录'),
              ),
            ],
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

/// 导出范围选择对话框:全部资产 / 当前筛选分类。
class _ExportScopeDialog extends StatefulWidget {
  const _ExportScopeDialog({required this.hasFilter});

  final bool hasFilter;

  @override
  State<_ExportScopeDialog> createState() => _ExportScopeDialogState();
}

class _ExportScopeDialogState extends State<_ExportScopeDialog> {
  String _scope = 'all';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导出资产'),
      content: RadioGroup<String>(
        groupValue: _scope,
        onChanged: (value) => setState(() => _scope = value ?? 'all'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              value: 'all',
              title: const Text('全部资产'),
            ),
            RadioListTile<String>(
              value: 'filter',
              title: const Text('当前筛选分类'),
              enabled: widget.hasFilter,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_scope),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

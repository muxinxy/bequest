import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/asset.dart';
import '../models/category.dart';
import '../models/trigger_ladder.dart';
import '../repository/asset_repository.dart';
import '../repository/local_asset_repository.dart';
import '../repository/offline_asset_repository.dart';
import '../storage/secure_store.dart';
import '../utils/time_format.dart';
import '../widgets/ladder_dropdown.dart';
import 'asset_edit_page.dart';
import 'category_inheritors_page.dart';

/// 分组详情:展示分组内资产列表(名称/继承人/状态/修改时间),
/// 支持搜索、排序(名称/修改时间/状态)与多选操作(删除/复制/移动/设置继承人)。
/// [category] 为 null 时表示「未分组」特殊分组。
class GroupDetailPage extends StatefulWidget {
  const GroupDetailPage({
    super.key,
    this.category,
    required this.repository,
    this.tier,
  });

  final Category? category;
  final AssetRepository repository;
  final String? tier;

  @override
  State<GroupDetailPage> createState() => _GroupDetailPageState();
}

/// 资产排序方式。
enum _AssetSort { name, updated, status }

class _GroupDetailPageState extends State<GroupDetailPage> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  /// 搜索防抖:输入停顿 300ms 后调 API 搜索。
  Timer? _searchDebounce;

  /// 分页大小(云端按分组分页;本地/离线忽略分页参数,全量返回)。
  static const _pageSize = 200;

  List<Asset> _assets = const [];
  List<Category> _categories = const [];

  /// 服务端统计的总数(懒加载判断用)。
  int _total = 0;
  bool _loadingMore = false;

  /// assetId → 继承人名列表(云端逐资产拉取;本地/离线为空)。
  Map<String, List<String>> _inheritors = const {};
  String _search = '';
  _AssetSort _sort = _AssetSort.name;
  final Set<String> _selectedIds = {};
  bool _multiSelect = false;
  bool _loading = true;

  /// 分组名(重命名后更新,标题即时反映)。
  String _groupName = '';

  bool get _isLocal => widget.repository is LocalAssetRepository;
  bool get _isOffline => widget.repository is OfflineAssetRepository;
  bool get _readOnly => _isOffline;
  String get _groupId => widget.category?.id ?? '';

  static const _statusLabels = {
    'active': '正常',
    'inactive': '停用',
    'pending': '待处理',
    'expired': '已过期',
  };
  static const _statusIcons = {
    'active': Icons.check_circle,
    'inactive': Icons.pause_circle_outline,
    'pending': Icons.hourglass_top,
    'expired': Icons.error_outline,
  };
  static const _statusColors = {
    'active': Colors.green,
    'inactive': Colors.grey,
    'pending': Colors.orange,
    'expired': Colors.red,
  };

  @override
  void initState() {
    super.initState();
    _groupName = widget.category?.name ?? '未分组';
    _scrollController.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// 滚动接近底部时加载下一页(搜索时不做:搜索基于已加载列表)。
  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  bool get _hasMore => _assets.length < _total;

  Future<void> _load() async {
    try {
      // 云端按分组分页拉取(q 非空时按资产名搜索);本地/离线忽略分页参数,全量返回。
      final (items, total) = await widget.repository.listAssetsPaged(
        categoryId: _groupId.isEmpty ? '0' : _groupId,
        q: _search,
        limit: _pageSize,
        offset: 0,
      );
      final inGroup = items.map(Asset.fromJson).toList(growable: false);
      final categories = (await widget.repository.listCategories())
          .map(Category.fromJson)
          .toList(growable: false);
      final inheritors = await _fetchInheritors(inGroup);
      if (!mounted) return;
      setState(() {
        _assets = inGroup;
        _total = total;
        _categories = categories;
        _inheritors = inheritors;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isLocal ? '加载失败,本地数据读取异常' : '加载失败,请检查网络后重试')),
      );
      Navigator.of(context).pop();
    }
  }

  /// 并行拉取各资产继承人(仅云端有数据;本地/离线返回空)。
  Future<Map<String, List<String>>> _fetchInheritors(List<Asset> assets) async {
    final inheritors = <String, List<String>>{};
    await Future.wait(
      assets.map((a) async {
        try {
          final names = (await widget.repository.listAssetInheritors(a.id))
              .map((m) => '${m['inheritor_name'] ?? ''}')
              .where((n) => n.isNotEmpty)
              .toList();
          if (names.isNotEmpty) inheritors[a.id] = names;
        } catch (_) {
          // 单资产继承人拉取失败不影响列表。
        }
      }),
    );
    return inheritors;
  }

  /// 懒加载下一页:offset 按已加载条数推进,追加到 _assets。
  /// 搜索时也带 q 继续分页(不再跳过,避免搜索结果被 200 条上限截断)。
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final (items, total) = await widget.repository.listAssetsPaged(
        categoryId: _groupId.isEmpty ? '0' : _groupId,
        q: _search,
        limit: _pageSize,
        offset: _assets.length,
      );
      final more = items.map(Asset.fromJson).toList(growable: false);
      final inheritors = await _fetchInheritors(more);
      if (!mounted) return;
      setState(() {
        _assets = [..._assets, ...more];
        _total = total;
        _inheritors = {..._inheritors, ...inheritors};
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// 搜索 + 排序后的可见资产。
  /// 搜索时 _assets 已是 API 按 q 过滤的结果,这里仅做排序;
  /// 本地/离线模式 _assets 为全量,仍按名称本地过滤。
  List<Asset> get _visibleAssets {
    final query = _search.trim().toLowerCase();
    final list = query.isEmpty
        ? _assets
        : _assets.where((a) => a.name.toLowerCase().contains(query)).toList();
    final sorted = [...list];
    switch (_sort) {
      case _AssetSort.name:
        sorted.sort((a, b) => a.name.compareTo(b.name));
      case _AssetSort.updated:
        sorted.sort((a, b) => (b.updatedAt ?? '').compareTo(a.updatedAt ?? ''));
      case _AssetSort.status:
        sorted.sort(
          (a, b) => _statusOrder(a.status).compareTo(_statusOrder(b.status)),
        );
    }
    return sorted;
  }

  static int _statusOrder(String s) => switch (s) {
    'active' => 0,
    'pending' => 1,
    'inactive' => 2,
    'expired' => 3,
    _ => 4,
  };

  Future<void> _openEditor(Asset asset) async {
    if (_readOnly) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('离线模式仅可查看与导出,无法修改资产')));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AssetEditPage(
          asset: asset,
          repository: widget.repository,
          tier: widget.tier,
        ),
      ),
    );
    if (mounted) _load();
  }

  // ---------- 多选操作 ----------

  Future<void> _deleteSelected() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除资产'),
        content: Text('确定删除所选 ${_selectedIds.length} 个资产?删除后资产将进入回收站,可在回收站恢复。'),
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
      await widget.repository.batchDeleteAssets(_selectedIds.toList());
      _exitMultiSelect();
      await _load();
    } catch (_) {
      _showError(_isLocal ? '删除失败,请重试' : '删除失败,请检查网络后重试');
    }
  }

  /// 复制到分组:先选目标分组(未分组或任一现有分组),逐条复制后移动过去。
  /// 后端 copyAsset 会保留原分组,故前端"复制后移动"落到所选分组。
  Future<void> _copySelected() async {
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('复制到分组'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('未分组'),
          ),
          for (final c in _categories)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(c.id),
              child: Text(c.name),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    try {
      for (final id in _selectedIds) {
        final copied = await widget.repository.copyAsset(id);
        final newId = copied['id']?.toString();
        if (newId == null || newId.isEmpty) continue;
        await widget.repository.moveAssets([
          newId,
        ], target.isEmpty ? null : target);
      }
      _exitMultiSelect();
      await _load();
    } catch (_) {
      _showError(_isLocal ? '复制失败,请重试' : '复制失败,请检查网络后重试');
    }
  }

  Future<void> _moveSelected() async {
    final targets = _categories.where((c) => c.id != _groupId).toList();
    final target = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('移动到分组'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('未分组'),
          ),
          for (final c in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(c.id),
              child: Text(c.name),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    try {
      await widget.repository.moveAssets(
        _selectedIds.toList(),
        target.isEmpty ? null : target,
      );
      _exitMultiSelect();
      await _load();
    } catch (_) {
      _showError(_isLocal ? '移动失败,请重试' : '移动失败,请检查网络后重试');
    }
  }

  /// 设置继承人:多选继承人 + 选择触发阶梯,批量绑定到所有所选资产(仅云端)。
  Future<void> _setInheritors() async {
    final jwt = await SecureStore().readJwt();
    if (jwt == null || jwt.isEmpty) {
      _showError('未登录,无法设置继承人');
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
        final mk = await SecureStore().readMasterKey() ?? '';
        inheritors = await OfflineAssetRepository(
          masterKeyB64: mk,
        ).listInheritors();
        ladders = const [];
        _showError('离线,显示缓存继承人(绑定需联网)');
      } catch (_) {
        _showError('加载继承人失败,请检查网络后重试');
        return;
      }
    }
    if (inheritors.isEmpty) {
      _showError('暂无继承人,请先在设置中创建');
      return;
    }
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
      _showError('请至少选择一名继承人');
      return;
    }
    try {
      // 每个选中资产 × 每个选中继承人批量绑定,统一应用所选阶梯。
      for (final id in _selectedIds) {
        for (final iid in selected) {
          await widget.repository.createAssetInheritor(id, {
            'inheritor_id': int.tryParse(iid),
            'priority': 1,
            'ladder_id': ladderId,
          });
        }
      }
      _exitMultiSelect();
      await _load();
    } catch (_) {
      _showError('绑定失败');
    }
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelect = false;
      _selectedIds.clear();
    });
  }

  // ---------- 分组操作 ----------

  Future<void> _onMenu(String action) async {
    switch (action) {
      case 'rename':
        await _renameGroup();
      case 'inheritors':
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CategoryInheritorsPage(
              categoryId: _groupId,
              categoryName: _groupName,
              repository: widget.repository,
            ),
          ),
        );
      case 'remark':
        await _editRemark();
    }
  }

  Future<void> _renameGroup() async {
    final controller = TextEditingController(text: _groupName);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名分组'),
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
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('请输入分组名称')));
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
    if (name == null || name.isEmpty || name == _groupName || !mounted) return;
    try {
      await widget.repository.updateCategory(_groupId, {'name': name});
      setState(() => _groupName = name);
    } on ApiException catch (e) {
      // 重名返回 409:明确提示"分组已存在"。
      _showError(
        e.statusCode == 409
            ? '分组已存在'
            : (_isLocal ? '保存失败,请重试' : '保存失败,请检查网络后重试'),
      );
    } catch (_) {
      _showError(_isLocal ? '保存失败,请重试' : '保存失败,请检查网络后重试');
    }
  }

  Future<void> _editRemark() async {
    final controller = TextEditingController(
      text: widget.category?.remark ?? '',
    );
    final remark = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑备注'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '分组备注',
            hintText: '补充说明(可选)',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (remark == null || !mounted) return;
    try {
      await widget.repository.updateCategory(_groupId, {'remark': remark});
    } catch (_) {
      _showError(_isLocal ? '保存失败,请重试' : '保存失败,请检查网络后重试');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 排序菜单:按名称 / 修改时间 / 状态。
  Future<void> _pickSort() async {
    final choice = await showDialog<_AssetSort>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('资产排序'),
        children: [
          _sortOption(_AssetSort.name, '按名称'),
          _sortOption(_AssetSort.updated, '按修改时间'),
          _sortOption(_AssetSort.status, '按状态'),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _sort = choice);
  }

  Widget _sortOption(_AssetSort value, String label) {
    return SimpleDialogOption(
      onPressed: () => Navigator.of(context).pop(value),
      child: Row(
        children: [
          Icon(
            _sort == value
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
            color: _sort == value
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
    );
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_multiSelect ? '已选 ${_selectedIds.length} 项' : _groupName),
        actions: _multiSelect
            ? [
                IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
                  onPressed: _exitMultiSelect,
                ),
              ]
            : [
                // 未分组无分组操作;离线只读。
                if (_groupId.isNotEmpty && !_readOnly)
                  PopupMenuButton<String>(
                    tooltip: '分组操作',
                    onSelected: _onMenu,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'rename', child: Text('重命名')),
                      PopupMenuItem(
                        value: 'inheritors',
                        child: Text('设置分组继承人'),
                      ),
                      PopupMenuItem(value: 'remark', child: Text('编辑备注')),
                    ],
                  ),
              ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      Expanded(
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
                                      _searchDebounce?.cancel();
                                      setState(() => _search = '');
                                      _load();
                                    },
                                  ),
                          ),
                          onChanged: (value) {
                            setState(() => _search = value);
                            // 防抖 300ms 后调 API 搜索(清空时立即重载全量)。
                            _searchDebounce?.cancel();
                            _searchDebounce = Timer(
                              const Duration(milliseconds: 300),
                              _load,
                            );
                          },
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
                  child: _visibleAssets.isEmpty
                      ? _buildEmptyState()
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.builder(
                            controller: _scrollController,
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 88),
                            itemCount: _visibleAssets.length + (_hasMore ? 1 : 0),
                            itemBuilder: (context, index) {
                              if (index >= _visibleAssets.length) {
                                // 底部加载中指示(搜索时同样分页加载)。
                                return const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                );
                              }
                              return _assetCard(_visibleAssets[index]);
                            },
                          ),
                        ),
                ),
              ],
            ),
      bottomNavigationBar: _multiSelect ? _buildBottomBar() : null,
      floatingActionButton: _readOnly || _multiSelect
          ? null // 离线只读 / 多选模式:不提供添加入口。
          : FloatingActionButton(
              tooltip: '新增资产',
              onPressed: _addAsset,
              child: const Icon(Icons.add),
            ),
    );
  }

  /// 空态引导:分组内无资产(且未搜索)时提示点击右下角 + 添加;
  /// 搜索无结果时仅提示无匹配。
  Widget _buildEmptyState() {
    final noSearch = _search.trim().isEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              noSearch ? Icons.inventory_2_outlined : Icons.search_off,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              noSearch ? '该分组暂无资产' : '没有匹配的资产',
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (noSearch) ...[
              const SizedBox(height: 8),
              Text(
                '点击右下角 + 添加',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 新增资产:预选当前分组(未分组详情页则为未分组),进编辑页后刷新。
  Future<void> _addAsset() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AssetEditPage(
          repository: widget.repository,
          tier: widget.tier,
          initialCategoryId: _groupId.isEmpty ? null : _groupId,
        ),
      ),
    );
    if (mounted) _load();
  }

  Widget _buildBottomBar() {
    return BottomAppBar(
      child: Row(
        children: [
          TextButton.icon(
            onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除'),
          ),
          TextButton.icon(
            onPressed: _selectedIds.isEmpty ? null : _copySelected,
            icon: const Icon(Icons.copy_outlined),
            label: const Text('复制'),
          ),
          TextButton.icon(
            onPressed: _selectedIds.isEmpty ? null : _moveSelected,
            icon: const Icon(Icons.drive_file_move_outline),
            label: const Text('移动'),
          ),
          if (!_isLocal && !_isOffline)
            TextButton.icon(
              onPressed: _selectedIds.isEmpty ? null : _setInheritors,
              icon: const Icon(Icons.people_outline),
              label: const Text('继承人'),
            ),
        ],
      ),
    );
  }

  Widget _assetCard(Asset a) {
    final selected = _selectedIds.contains(a.id);
    final inheritors = _inheritors[a.id] ?? const [];
    final status = a.status;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: InkWell(
        onLongPress: _readOnly
            ? null
            : () => setState(() {
                _multiSelect = true;
                _selectedIds.add(a.id);
              }),
        onTap: _multiSelect
            ? () => setState(() {
                if (!_selectedIds.remove(a.id)) _selectedIds.add(a.id);
              })
            : () => _openEditor(a),
        child: ListTile(
          leading: Icon(
            _statusIcons[status] ?? Icons.inventory_2_outlined,
            color: _statusColors[status],
          ),
          title: Text(a.name),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (inheritors.isNotEmpty) Text('继承人:${inheritors.join('、')}'),
              Text('修改 ${formatServerTime(a.updatedAt)}'),
            ],
          ),
          trailing: _multiSelect
              ? Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : null,
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _statusLabels[status] ?? status,
                      style: TextStyle(
                        fontSize: 12,
                        color: _statusColors[status],
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
        ),
      ),
    );
  }
}

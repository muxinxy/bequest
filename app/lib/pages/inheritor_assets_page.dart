import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';

/// 查看某继承人绑定的所有资产(直接绑定 + 经分组继承),支持多选解绑。
/// 解绑资产级绑定删除 asset_inheritors 行;分组级绑定删除 category_inheritors 行。
/// [initialInheritorId] 指定后固定为该继承人(隐藏下拉),供继承人列表页跳转。
class InheritorAssetsPage extends StatefulWidget {
  const InheritorAssetsPage({
    super.key,
    required this.repository,
    this.initialInheritorId,
  });

  final AssetRepository repository;
  final String? initialInheritorId;

  @override
  State<InheritorAssetsPage> createState() => _InheritorAssetsPageState();
}

class _InheritorAssetsPageState extends State<InheritorAssetsPage> {
  final _store = SecureStore();

  List<Map<String, dynamic>> _inheritors = const [];
  String? _selectedId;
  List<Map<String, dynamic>> _assets = const [];
  final Set<int> _selected = {}; // 待解绑的 binding_id 集合
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadInheritors();
  }

  Future<void> _loadInheritors() async {
    try {
      final jwt = await _store.readJwt();
      final inheritors = jwt == null
          ? <Map<String, dynamic>>[]
          : await (await ApiConfig.client()).listInheritors(jwt);
      if (!mounted) return;
      setState(() => _inheritors = inheritors);
      // 指定了初始继承人:直接选中;否则默认第一个。
      final target = widget.initialInheritorId ??
          (inheritors.isEmpty ? null : '${inheritors.first['id']}');
      if (target != null) await _select(target);
    } catch (_) {
      // 加载失败:下拉框留空,页面显示"暂无继承人"。
    }
  }

  /// 固定继承人时显示其姓名(列表为空则兜底)。
  String get _inheritorName {
    final id = widget.initialInheritorId;
    for (final i in _inheritors) {
      if ('${i['id']}' == id) return '${i['name']}';
    }
    return '该继承人';
  }

  Future<void> _select(String id) async {    setState(() {
      _selectedId = id;
      _selected.clear();
      _loading = true;
    });
    try {
      final assets =
          await widget.repository.listInheritorAssets(id);
      if (mounted) {
        setState(() {
          _assets = assets;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _assets = const [];
          _loading = false;
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      }
    }
  }

  /// 分组继承预览:该分组下经此绑定继承的具体资产列表。
  Future<void> _previewGroupAssets(Map<String, dynamic> group) async {
    try {
      final data = await widget.repository.listCategoryInheritorAssets(
        '${group['category_id']}',
        '${group['binding_id']}',
      );
      if (!mounted) return;
      final assets = (data['assets'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
      await showDialog<void>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text('「${group['category_name'] ?? ''}」经分组继承的资产'),
          children: [
            if (assets.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('该分组下暂无资产'),
              ),
            for (final a in assets)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(),
                child: Row(
                  children: [
                    const Icon(Icons.inventory_2_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text('${a['name'] ?? ''}')),
                    if (a['expiry_date'] != null)
                      Text(
                        '到期 ${a['expiry_date']}',
                        style: const TextStyle(fontSize: 12, color: Colors.grey),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('预览失败,请检查网络后重试')));
    }
  }

  Future<void> _unbindSelected() async {
    if (_selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('解绑所选资产?'),
        content: Text('将解绑 ${_selected.length} 个资产的继承人绑定,解绑后这些资产'
            '继承触发时随全量交接。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('解绑'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      // 按 (类型, binding_id) 去重:同一分组绑定的多个资产共享同一个
      // category_inheritors 行,重复 DELETE 会第二次 404 报"解绑失败"。
      final done = <String>{};
      for (final b in _assets.where((a) => _selected.contains(a['binding_id']))) {
        final key = '${b['binding_type']}:${b['binding_id']}';
        if (!done.add(key)) continue;
        if ('${b['binding_type']}' == 'asset') {
          await widget.repository
              .deleteAssetInheritor('${b['asset_id']}', '${b['binding_id']}');
        } else {
          await widget.repository.deleteCategoryInheritor(
            '${b['category_id'] ?? ''}',
            '${b['binding_id']}',
          );
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已解绑')));
      final sel = _selectedId;
      if (sel != null) await _select(sel);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('解绑失败,请检查网络后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('继承人绑定资产')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: widget.initialInheritorId != null
                // 固定继承人:只显示姓名,不提供下拉选择。
                ? Text(
                    '继承人:$_inheritorName',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  )
                : _inheritors.isEmpty
                    ? const Text(
                        '暂无继承人,请先在「继承人」中创建',
                        style: TextStyle(color: Colors.grey),
                      )
                    : DropdownButtonFormField<String>(
                    initialValue: _selectedId,
                    decoration: const InputDecoration(
                      labelText: '选择继承人',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final i in _inheritors)
                        DropdownMenuItem(
                          value: '${i['id']}',
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${i['name']}${i['email'] == null || (i['email'] as String).isEmpty ? '' : ' (${i['email']})'}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                '${i['category_count'] ?? 0} 个分组 · ${i['asset_count'] ?? 0} 个资产',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) _select(v);
                    },
                  ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _assets.isEmpty
                    ? const Center(child: Text('该继承人暂无绑定'))
                    : ListView.builder(
                        itemCount: _assets.length,
                        itemBuilder: (context, index) {
                          final a = _assets[index];
                          final bindingId = a['binding_id'] as int? ?? 0;
                          final isSelected = _selected.contains(bindingId);
                          final viaGroup = '${a['binding_type']}' == 'category';
                          final days = a['trigger_days'];
                          // 分组行显示分组实体(含经分组继承的资产数);资产行显示资产。
                          final title = viaGroup
                              ? '分组「${a['category_name'] ?? ''}」'
                              : '${a['asset_name'] ?? ''}';
                          final subtitle = viaGroup
                              ? '经分组继承 · ${a['asset_count'] ?? 0} 个资产'
                                  '${days == null ? '' : ' · $days 天触发'}'
                              : '直接绑定'
                                  '${a['category_name'] == null || (a['category_name'] as String).isEmpty ? '' : ' · ${a['category_name']}'}'
                                  '${days == null ? '' : ' · $days 天触发'}';
                          return ListTile(
                            leading: Checkbox(
                              value: isSelected,
                              onChanged: (v) => setState(() {
                                if (v == true) {
                                  _selected.add(bindingId);
                                } else {
                                  _selected.remove(bindingId);
                                }
                              }),
                            ),
                            title: Text(title),
                            subtitle: Text(subtitle),
                            trailing: viaGroup
                                ? IconButton(
                                    tooltip: '预览资产',
                                    icon: const Icon(Icons.visibility_outlined),
                                    onPressed: () => _previewGroupAssets(a),
                                  )
                                : null,
                          );
                        },
                      ),
          ),
          if (_selected.isNotEmpty)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.link_off),
                    label: Text('解绑所选 (${_selected.length})'),
                    onPressed: _unbindSelected,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

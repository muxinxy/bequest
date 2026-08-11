import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';

/// 查看某继承人绑定的所有资产(直接绑定 + 经分组继承),支持多选解绑。
/// 解绑资产级绑定删除 asset_inheritors 行;分组级绑定删除 category_inheritors 行。
class InheritorAssetsPage extends StatefulWidget {
  const InheritorAssetsPage({super.key, required this.repository});

  final AssetRepository repository;

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
      if (mounted) {
        setState(() => _inheritors = inheritors);
        if (inheritors.isNotEmpty) {
          await _select('${inheritors.first['id']}');
        }
      }
    } catch (_) {
      // 加载失败:下拉框留空,页面显示"暂无继承人"。
    }
  }

  Future<void> _select(String id) async {
    setState(() {
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
      for (final b in _assets.where((a) => _selected.contains(a['binding_id']))) {
        if ('${b['binding_type']}' == 'asset') {
          await widget.repository
              .deleteAssetInheritor('${b['asset_id']}', '${b['binding_id']}');
        } else {
          await widget.repository
              .deleteCategoryInheritor('${b['category_id'] ?? ''}', '${b['binding_id']}');
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
            child: _inheritors.isEmpty
                ? const Text('暂无继承人,请先在「继承人」中创建', style: TextStyle(color: Colors.grey))
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
                          child: Text(
                            '${i['name']}${i['email'] == null ? '' : ' (${i['email']})'}',
                            overflow: TextOverflow.ellipsis,
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
                    ? const Center(child: Text('该继承人暂无绑定资产'))
                    : ListView.builder(
                        itemCount: _assets.length,
                        itemBuilder: (context, index) {
                          final a = _assets[index];
                          final bindingId = a['binding_id'] as int? ?? 0;
                          final isSelected = _selected.contains(bindingId);
                          final viaGroup = '${a['binding_type']}' == 'category';
                          final days = a['trigger_days'];
                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (v) => setState(() {
                              if (v == true) {
                                _selected.add(bindingId);
                              } else {
                                _selected.remove(bindingId);
                              }
                            }),
                            title: Text('${a['asset_name'] ?? ''}'),
                            subtitle: Text(
                              '${viaGroup ? '经分组' : '直接绑定'}'
                              '${a['category_name'] == null ? '' : ' · ${a['category_name']}'}'
                              '${days == null ? '' : ' · $days 天触发'}',
                            ),
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

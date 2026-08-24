import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../storage/secure_store.dart';

/// 继承触发预览:展示触发阶梯、交接范围、继承人与交接说明。
/// 数据来自 GET /api/v1/inheritance/preview。
class InheritancePreviewPage extends StatefulWidget {
  const InheritancePreviewPage({super.key});

  @override
  State<InheritancePreviewPage> createState() => _InheritancePreviewPageState();
}

class _InheritancePreviewPageState extends State<InheritancePreviewPage> {
  final _store = SecureStore();

  Map<String, dynamic> _data = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null || jwt.isEmpty) throw ApiException('未登录');
      final json = await (await ApiConfig.client()).getInheritancePreview(jwt);
      if (!mounted) return;
      setState(() {
        _data = json;
        _loading = false;
      });
    } catch (_) {
      // 加载失败/未登录:提示后返回。
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  /// 触发条件卡片:阶梯 2 档 + 大字提示。
  Widget _triggerCard() {
    final ladder = _data['ladder'] as Map<String, dynamic>? ?? const {};
    final days = (ladder['days'] as List? ?? const []).whereType<num>().toList();
    final name = ladder['name']?.toString() ?? '';
    final triggerDays = (_data['trigger_days'] as num?)?.toInt() ?? 0;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.timelapse, color: scheme.primary),
                const SizedBox(width: 8),
                const Text('触发条件', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                // 阶梯名:全局/自定义。
                Text(
                  name.isEmpty ? '' : '阶梯:$name',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 2 档天数展示(一级 / 二级)。
            Text(
              days.length >= 2
                  ? '一级 ${days[0].toInt()} 天  →  二级 ${days[1].toInt()} 天'
                  : '',
              style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              '失联超过 $triggerDays 天将触发继承',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: scheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 交接范围卡片:资产总数 + 可展开的资产清单。
  Widget _handoverCard() {
    final total = (_data['total_assets'] as num?)?.toInt() ?? 0;
    final inherited = (_data['inherited_assets'] as num?)?.toInt() ?? 0;
    final assets = (_data['assets'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                const Text('交接范围', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              total == inherited
                  ? '共 $total 个资产,全部将交接'
                  : '共 $total 个资产,其中 $inherited 个将交接',
              style: const TextStyle(fontSize: 14),
            ),
            if (assets.isNotEmpty) ...[
              const SizedBox(height: 4),
              // 可展开的资产清单。
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text('资产清单(${assets.length})'),
                children: [
                  for (final a in assets) _assetTile(a),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 单个资产:资产名 + 继承人(via=user 显示"用户级全量")。
  Widget _assetTile(Map<String, dynamic> asset) {
    final name = asset['name']?.toString() ?? '未命名资产';
    final via = asset['via']?.toString() ?? '';
    final inheritorName = via == 'user'
        ? '用户级全量'
        : asset['inheritor_name']?.toString();
    final subtitle = via == 'user'
        ? '用户级全量交接'
        : '继承人:${inheritorName == null || inheritorName.isEmpty ? '未指定' : inheritorName}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_outlined, size: 20),
      title: Text(name),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
    );
  }

  /// 继承人卡片列表。
  Widget _inheritorsCard() {
    final inheritors = (_data['inheritors'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    // 接收用户级全量交接的继承人名单。
    final levelNames = (_data['user_level_inheritors'] as List? ?? const [])
        .whereType<String>()
        .toSet();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.people_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                const Text('继承人', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            if (inheritors.isEmpty)
              const Text('暂无继承人', style: TextStyle(fontSize: 14))
            else
              for (final inh in inheritors) _inheritorTile(inh, levelNames),
          ],
        ),
      ),
    );
  }

  Widget _inheritorTile(Map<String, dynamic> inh, Set<String> levelNames) {
    final name = inh['name']?.toString() ?? '未命名';
    final email = inh['email']?.toString() ?? '';
    final phone = inh['phone']?.toString() ?? '';
    final count = (inh['asset_count'] as num?)?.toInt() ?? 0;
    final isLevel = levelNames.contains(name);
    final contact = [if (email.isNotEmpty) email, if (phone.isNotEmpty) phone]
        .join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CircleAvatar(radius: 16, child: Icon(Icons.person, size: 18)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (contact.isNotEmpty)
                  Text(contact, style: const TextStyle(fontSize: 12)),
                Text('覆盖 $count 个资产', style: const TextStyle(fontSize: 12)),
                if (isLevel)
                  Text(
                    '将接收用户级全量交接',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 交接说明卡片。
  Widget _noteCard() {
    final note = _data['note']?.toString() ?? '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                const Text('交接说明', style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            if (note.isNotEmpty)
              Text(note, style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 8),
            const Text(
              '登录即可取消继承;继承人领取密钥后 72 小时内可撤销。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('继承预览')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _triggerCard(),
                const SizedBox(height: 16),
                _handoverCard(),
                const SizedBox(height: 16),
                _inheritorsCard(),
                const SizedBox(height: 16),
                _noteCard(),
              ],
            ),
    );
  }
}

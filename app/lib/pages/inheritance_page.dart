import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/inheritance_status.dart';
import '../storage/secure_store.dart';
import '../utils/time_format.dart';

/// 继承:合并原 继承开关 + 继承状态 + 继承预览 为单页。
/// 自上而下:开关 → 状态 → 触发条件 → 交接范围(资产/继承人/默认继承人)→ 说明。
class InheritancePage extends StatefulWidget {
  const InheritancePage({super.key});

  @override
  State<InheritancePage> createState() => _InheritancePageState();
}

class _InheritancePageState extends State<InheritancePage> {
  final _store = SecureStore();

  bool _loading = true;
  bool _inheritanceEnabled = true;
  InheritanceStatus? _status;
  Map<String, dynamic> _preview = const {};
  int? _defaultInheritorId;
  String? _defaultInheritorName;
  bool _showAllAssets = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null || jwt.isEmpty) throw ApiException('未登录');
      final api = await ApiConfig.client();
      // 并行拉取:开关 / 状态 / 预览 / 默认继承人。
      final results = await Future.wait([
        api.getInheritanceToggle(jwt),
        api.getInheritanceStatus(jwt),
        api.getInheritancePreview(jwt),
        api.getDefaultInheritor(jwt),
      ]);
      if (!mounted) return;
      setState(() {
        _inheritanceEnabled = results[0]['enabled'] == true;
        _status = InheritanceStatus.fromJson(results[1]);
        _preview = results[2];
        _defaultInheritorId = (results[3]['inheritor_id'] as num?)?.toInt();
        _defaultInheritorName = results[3]['inheritor_name']?.toString();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  Future<void> _toggleInheritance(bool value) async {
    setState(() => _inheritanceEnabled = value);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) return;
      await (await ApiConfig.client()).putInheritanceToggle(jwt, value);
    } catch (_) {
      if (!mounted) return;
      setState(() => _inheritanceEnabled = !value);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('开关保存失败,请检查网络后重试')));
    }
  }

  static String _stageLabel(String? stage) => switch (stage) {
        'inactive' => '未触发',
        'warning' => '提醒中',
        'triggered' => '已触发',
        'claimed' => '已领取',
        'reversed' => '已撤销',
        _ => stage == null || stage.isEmpty ? '未知' : stage,
      };

  static IconData _stageIcon(String? stage) => switch (stage) {
        'inactive' => Icons.shield_outlined,
        'warning' => Icons.warning_amber_rounded,
        'triggered' => Icons.notification_important,
        'claimed' => Icons.key,
        'reversed' => Icons.undo,
        _ => Icons.help_outline,
      };

  static String _eventStatusLabel(String status) => switch (status) {
        'created' => '已创建',
        'claimed' => '已领取',
        'reversed' => '已撤销',
        _ => status,
      };

  /// 开关卡片:一键开启/关闭继承。
  Widget _toggleCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: SwitchListTile(
        secondary: Icon(Icons.power_settings_new, color: scheme.primary),
        title: const Text('继承开关'),
        subtitle: const Text('关闭后不触发继承交接', style: TextStyle(fontSize: 12)),
        value: _inheritanceEnabled,
        onChanged: _toggleInheritance,
      ),
    );
  }

  /// 状态卡片:当前阶段/升级等级/最近登录 + 继承事件列表。
  Widget _statusCard() {
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_stageIcon(status.stage), size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '当前阶段:${_stageLabel(status.stage)}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '升级等级:${status.escalationLevel ?? 0}'
                        '${status.lastLoginAt == null ? '' : ' · 最近登录 ${formatServerTime(status.lastLoginAt)}'}',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('继承事件', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            if (status.events.isEmpty)
              const Text('暂无继承事件', style: TextStyle(fontSize: 14))
            else
              for (final e in status.events)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${_eventStatusLabel(e.status)}'
                          '${e.createdAt == null ? '' : ' · 创建 ${formatServerTime(e.createdAt)}'}'
                          '${e.claimedAt == null ? '' : ' · 领取 ${formatServerTime(e.claimedAt)}'}'
                          '${e.reversedAt == null ? '' : ' · 撤销 ${formatServerTime(e.reversedAt)}'}'),
                      if (e.status == 'claimed' && e.reversableUntil != null)
                        Text(
                          '反悔截止:${formatServerTime(e.reversableUntil)}(过期后交接最终完成)',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.orange,
                          ),
                        ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  /// 触发条件卡片:阶梯 2 档 + 大字提示。
  Widget _triggerCard() {
    final ladder = _preview['ladder'] as Map<String, dynamic>? ?? const {};
    final days = (ladder['days'] as List? ?? const []).whereType<num>().toList();
    final name = ladder['name']?.toString() ?? '';
    final triggerDays = (_preview['trigger_days'] as num?)?.toInt() ?? 0;
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
                Text(
                  name.isEmpty ? '' : '阶梯:$name',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 12),
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

  /// 交接范围卡片:资产总数 + 可展开资产清单。
  Widget _handoverCard() {
    final total = (_preview['total_assets'] as num?)?.toInt() ?? 0;
    final inherited = (_preview['inherited_assets'] as num?)?.toInt() ?? 0;
    final assets = (_preview['assets'] as List? ?? const [])
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
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text('资产清单(${assets.length})'),
                // 资产 >20 条时默认只显示前 20,底部"展开全部 N 条"按钮。
                children: [
                  for (final a in _showAllAssets || assets.length <= 20
                      ? assets
                      : assets.take(20))
                    _assetTile(a),
                  if (assets.length > 20 && !_showAllAssets)
                    Center(
                      child: TextButton(
                        onPressed: () => setState(() => _showAllAssets = true),
                        child: Text('展开全部 ${assets.length} 条'),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 单个资产:资产名 + 继承人(via=user 显示"用户级全量 → 继承人名")。
  Widget _assetTile(Map<String, dynamic> asset) {
    final name = asset['name']?.toString() ?? '未命名资产';
    final via = asset['via']?.toString() ?? '';
    if (via == 'user') {
      // 具体继承人:已设默认继承人,否则取 user_level_inheritors 第一顺位。
      final levelNames = (_preview['user_level_inheritors'] as List? ?? const [])
          .whereType<String>()
          .toList();
      final levelName = _defaultInheritorName?.isNotEmpty == true
          ? _defaultInheritorName
          : levelNames.isEmpty
              ? null
              : levelNames.first;
      final subtitle = levelName == null || levelName.isEmpty
          ? '用户级全量'
          : '用户级全量 → $levelName';
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.folder_outlined, size: 20),
        title: Text(name),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      );
    }
    final inheritorName = asset['inheritor_name']?.toString();
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.folder_outlined, size: 20),
      title: Text(name),
      subtitle: Text(
        '继承人:${inheritorName == null || inheritorName.isEmpty ? '未指定' : inheritorName}',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  /// 继承人卡片:名单 + 用户级全量标注 + 默认继承人设置。
  Widget _inheritorsCard() {
    final inheritors = (_preview['inheritors'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final levelNames = (_preview['user_level_inheritors'] as List? ?? const [])
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
            const Divider(height: 24),
            const Text('默认继承人', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _defaultInheritorName == null || _defaultInheritorName!.isEmpty
                        ? '未指定(继承触发时按第一顺位分配)'
                        : '$_defaultInheritorName(ID $_defaultInheritorId)',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                TextButton(
                  onPressed: _pickDefaultInheritor,
                  child: const Text('设置'),
                ),
              ],
            ),
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

  /// 设置默认继承人:列出全部继承人,含"不指定(按第一顺位)"。
  /// 返回值:-1 表示不指定,其它为正数继承人或 null 表示取消。
  Future<void> _pickDefaultInheritor() async {
    const int unspecified = -1;
    final jwt = await _store.readJwt();
    if (jwt == null || jwt.isEmpty) return;
    final api = await ApiConfig.client();
    final inheritors = await api.listInheritors(jwt);
    if (!mounted) return;
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('设置默认继承人'),
        children: [
          for (final i in inheritors)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(
                int.tryParse(i['id']?.toString() ?? '') ?? 0,
              ),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(i['name']?.toString() ?? '未命名'),
                subtitle: Text(
                  '${i['category_count'] ?? 0} 个分组 · ${i['asset_count'] ?? 0} 个资产',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(unspecified),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.clear),
              title: Text('不指定(按第一顺位)'),
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    final bodyId = picked == unspecified ? null : picked;
    try {
      await api.putDefaultInheritor(jwt, bodyId);
      if (!mounted) return;
      // 重新拉取:刷新 preview 的 user_level_inheritors / 资产覆盖数。
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('默认继承人已保存')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('保存失败,请检查网络后重试')));
    }
  }

  /// 交接说明卡片。
  Widget _noteCard() {
    final note = _preview['note']?.toString() ?? '';
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
      appBar: AppBar(title: const Text('继承')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _toggleCard(),
                const SizedBox(height: 16),
                _statusCard(),
                const SizedBox(height: 16),
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

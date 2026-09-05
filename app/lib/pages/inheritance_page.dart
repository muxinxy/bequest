import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../l10n/app_l10n.dart';
import '../models/inheritance_status.dart';
import '../storage/secure_store.dart';
import '../utils/time_format.dart';
import 'inheritance_events_page.dart';

/// 继承:开关 → 状态 → 默认继承人 → 说明。
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
  int? _defaultInheritorId;
  String? _defaultInheritorName;

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
      // 并行拉取:开关 / 状态 / 默认继承人。
      final results = await Future.wait([
        api.getInheritanceToggle(jwt),
        api.getInheritanceStatus(jwt),
        api.getDefaultInheritor(jwt),
      ]);
      if (!mounted) return;
      setState(() {
        _inheritanceEnabled = results[0]['enabled'] == true;
        _status = InheritanceStatus.fromJson(results[1]);
        _defaultInheritorId = (results[2]['inheritor_id'] as num?)?.toInt();
        _defaultInheritorName = results[2]['inheritor_name']?.toString();
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L10n.tr('加载失败,请检查网络后重试'))));
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
      ).showSnackBar(SnackBar(content: Text(L10n.tr('开关保存失败,请检查网络后重试'))));
    }
  }

  static String _stageLabel(String? stage) => switch (stage) {
        'inactive' => L10n.tr('未触发'),
        'warning' => L10n.tr('提醒中'),
        'triggered' => L10n.tr('已触发'),
        'claimed' => L10n.tr('已领取'),
        'reversed' => L10n.tr('已撤销'),
        _ => stage == null || stage.isEmpty ? L10n.tr('未知') : stage,
      };

  static IconData _stageIcon(String? stage) => switch (stage) {
        'inactive' => Icons.shield_outlined,
        'warning' => Icons.warning_amber_rounded,
        'triggered' => Icons.notification_important,
        'claimed' => Icons.key,
        'reversed' => Icons.undo,
        _ => Icons.help_outline,
      };

  /// 开关卡片:一键开启/关闭继承。
  Widget _toggleCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: SwitchListTile(
        secondary: Icon(Icons.power_settings_new, color: scheme.primary),
        title: Text(L10n.tr('继承开关')),
        subtitle: Text(L10n.tr('关闭后不触发继承交接'), style: const TextStyle(fontSize: 12)),
        value: _inheritanceEnabled,
        onChanged: _toggleInheritance,
      ),
    );
  }

  /// 状态卡片:当前阶段/升级等级/最近登录。
  Widget _statusCard() {
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(_stageIcon(status.stage), size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    L10n.trp('当前阶段:{stage}', {'stage': _stageLabel(status.stage)}),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    L10n.trp('升级等级:{n}', {'n': '${status.escalationLevel ?? 0}'}) +
                        (status.lastLoginAt == null
                            ? ''
                            : L10n.trp(' · 最近登录 {time}', {
                                'time': formatServerTime(status.lastLoginAt),
                              })),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 继承事件记录入口:跳转独立事件页(年月筛选/搜索/导出)。
  Widget _eventsEntryCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: Icon(Icons.history, color: scheme.primary),
        title: Text(L10n.tr('查看事件记录')),
        subtitle: Text(
          L10n.tr('继承事件永久保留,支持年月筛选与 CSV 导出'),
          style: const TextStyle(fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const InheritanceEventsPage()),
        ),
      ),
    );
  }

  /// 默认继承人卡片:显示当前默认继承人 + 设置按钮。
  Widget _defaultInheritorCard() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.person_pin_outlined, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(L10n.tr('默认继承人'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(
                    _defaultInheritorName == null || _defaultInheritorName!.isEmpty
                        ? L10n.tr('未指定(继承触发时按第一顺位分配)')
                        : L10n.trp('{name}(ID {id})', {
                            'name': _defaultInheritorName!,
                            'id': '$_defaultInheritorId',
                          }),
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _pickDefaultInheritor,
              child: Text(L10n.tr('设置')),
            ),
          ],
        ),
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
        title: Text(L10n.tr('设置默认继承人')),
        children: [
          for (final i in inheritors)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(
                int.tryParse(i['id']?.toString() ?? '') ?? 0,
              ),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.person_outline),
                title: Text(i['name']?.toString() ?? L10n.tr('未命名')),
                subtitle: Text(
                  L10n.trp('{n} 个分组 · {m} 个资产', {
                    'n': '${i['category_count'] ?? 0}',
                    'm': '${i['asset_count'] ?? 0}',
                  }),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(unspecified),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.clear),
              title: Text(L10n.tr('不指定(按第一顺位)')),
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
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L10n.tr('默认继承人已保存'))));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(L10n.tr('保存失败,请检查网络后重试'))));
    }
  }

  /// 交接说明卡片(通用文案,不含具体天数)。
  Widget _noteCard() {
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
                Text(L10n.tr('交接说明'), style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              L10n.tr(
                '失联超过触发阶梯末档将触发继承,继承人凭继承码领取密钥,原主登录可在 72 小时内撤销。',
              ),
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.tr('继承'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _toggleCard(),
                const SizedBox(height: 16),
                _statusCard(),
                const SizedBox(height: 16),
                _eventsEntryCard(),
                const SizedBox(height: 16),
                _defaultInheritorCard(),
                const SizedBox(height: 16),
                _noteCard(),
              ],
            ),
    );
  }
}

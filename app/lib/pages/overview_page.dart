import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../l10n/app_l10n.dart';
import '../storage/secure_store.dart';
import 'membership_page.dart';
import 'reminders_page.dart';

/// 总览页:独立展示资产/统计/提醒/用量/会员等汇总数据。
/// 打开时拉取 GET /api/v1/overview(需 jwt);失败显示"加载失败"可重试。
class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _error = false;

  /// 资产状态色/文案(与 group_detail 一致)。
  static const _statusColors = {
    'active': Colors.green,
    'inactive': Colors.grey,
    'pending': Colors.orange,
    'expired': Colors.red,
  };
  static const _statusLabels = {
    'active': '正常',
    'inactive': '停用',
    'pending': '待处理',
    'expired': '已过期',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final jwt = await SecureStore().readJwt();
      if (jwt == null || jwt.isEmpty) {
        setState(() {
          _loading = false;
          _error = true;
        });
        return;
      }
      final api = await ApiConfig.client();
      final data = await api.getOverview(jwt);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.tr('总览')),
        actions: [
          IconButton(
            tooltip: L10n.tr('刷新'),
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error
              ? _buildError()
              : _buildContent(),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(L10n.tr('加载失败')),
          const SizedBox(height: 8),
          FilledButton(onPressed: _load, child: Text(L10n.tr('重试'))),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final o = _data ?? const {};
    final assets = (o['assets'] as Map<String, dynamic>?) ?? const {};
    final counts = (o['counts'] as Map<String, dynamic>?) ?? const {};
    final reminders = (o['reminders'] as Map<String, dynamic>?) ?? const {};
    final quota = (o['quota'] as Map<String, dynamic>?) ?? const {};
    final membership = (o['membership'] as Map<String, dynamic>?) ?? const {};
    final expiring = (assets['expiring_soon'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final unread = (reminders['unread'] as num?)?.toInt() ?? 0;
    final recent = (reminders['recent'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final tier = membership['tier'] as String? ?? 'free';
    final isMember = tier == 'member';
    final memberExpires = (membership['member_expires_at'] as String?) ?? '';
    final emailUsed = (quota['email_used'] as num?)?.toInt() ?? 0;
    final emailLimit = (quota['email_limit'] as num?)?.toInt() ?? 0;
    final smsUsed = (quota['sms_used'] as num?)?.toInt() ?? 0;
    final smsLimit = (quota['sms_limit'] as num?)?.toInt() ?? 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _assetCard(assets),
        if (expiring.isNotEmpty) _expiringCard(expiring),
        _statsCard(counts),
        _reminderCard(unread, recent),
        _quotaCard(emailUsed, emailLimit, smsUsed, smsLimit, isMember),
        _memberCard(isMember, memberExpires),
      ],
    );
  }

  /// 资产概览:渐变大数字 + 2x2 状态分布。
  Widget _assetCard(Map<String, dynamic> assets) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [scheme.primary, scheme.primaryContainer],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${assets['total'] ?? 0}',
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.bold,
                color: scheme.onPrimary,
              ),
            ),
            Text(
              L10n.tr('资产总数'),
              style: TextStyle(
                color: scheme.onPrimary.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(height: 16),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              // 固定行高,避免窄屏下 aspectRatio 导致过高空白。
              mainAxisExtent: 28,
              children: [
                for (final s in const ['active', 'inactive', 'pending', 'expired'])
                  _statusItem(s, assets[s] ?? 0, onPrimary: true),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusItem(String key, int value, {bool onPrimary = false}) {
    final scheme = Theme.of(context).colorScheme;
    final fg = onPrimary ? scheme.onPrimary : scheme.onSurface;
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: _statusColors[key],
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text('$value', style: TextStyle(fontWeight: FontWeight.w600, color: fg)),
        const SizedBox(width: 4),
        Text(
          L10n.tr(_statusLabels[key]!),
          style: TextStyle(
            fontSize: 12,
            color: fg.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }

  /// 即将到期(30 天内):最多 5 条,超出显示剩余条数;空则不显示。
  Widget _expiringCard(List<Map<String, dynamic>> expiring) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.event_available, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  L10n.tr('即将到期(30 天内)'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final e in expiring.take(5))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _statusColors[e['status']] ?? Colors.grey,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${e['name']}', overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      '${e['expiry_date']}',
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            if (expiring.length > 5)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  L10n.trp('还有 {n} 项即将到期', {
                    'n': '${expiring.length - 5}',
                  }),
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 统计:分组 / 继承人 / 触发阶梯 三列并排。
  Widget _statsCard(Map<String, dynamic> counts) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            _statItem(L10n.tr('分组'), counts['categories'] ?? 0),
            _statItem(L10n.tr('继承人'), counts['inheritors'] ?? 0),
            _statItem(L10n.tr('触发阶梯'), counts['trigger_ladders'] ?? 0),
          ],
        ),
      ),
    );
  }

  Widget _statItem(String label, int value) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 提醒:未读数 + 最近提醒标题,点击进提醒页。
  Widget _reminderCard(int unread, List<Map<String, dynamic>> recent) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const RemindersPage()),
        ),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.notifications_outlined, size: 20, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text(L10n.tr('提醒'), style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  if (unread > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: scheme.errorContainer,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        L10n.trp('{n} 未读', {'n': '$unread'}),
                        style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
                      ),
                    ),
                  Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
                ],
              ),
              if (recent.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final r in recent.take(3))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${r['title']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 通知用量:邮件进度条;会员额外短信条,免费仅邮件。
  Widget _quotaCard(
    int emailUsed,
    int emailLimit,
    int smsUsed,
    int smsLimit,
    bool isMember,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notifications_active_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(L10n.tr('通知用量'), style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            _usageBar(L10n.tr('邮件'), emailUsed, emailLimit),
            if (isMember) ...[
              const SizedBox(height: 12),
              _usageBar(L10n.tr('短信'), smsUsed, smsLimit),
            ],
          ],
        ),
      ),
    );
  }

  Widget _usageBar(String label, int used, int limit) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
            const Spacer(),
            Text('$used/$limit', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: ratio, minHeight: 6),
        ),
      ],
    );
  }

  /// 会员:层级 + 到期时间(空=永久),点击进会员页。
  Widget _memberCard(bool isMember, String memberExpires) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(
          isMember ? Icons.workspace_premium : Icons.circle_outlined,
          color: isMember ? const Color(0xFFFFD700) : scheme.onSurfaceVariant,
        ),
        title: Text(isMember ? L10n.tr('会员') : L10n.tr('免费')),
        subtitle: Text(
          isMember
              ? (memberExpires.isEmpty
                    ? L10n.tr('永久有效')
                    : L10n.trp('到期时间:{time}', {'time': memberExpires}))
              : L10n.tr('升级会员解锁更多权益'),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const MembershipPage()),
        ),
      ),
    );
  }
}

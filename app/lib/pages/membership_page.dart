import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../l10n/app_l10n.dart';
import '../models/entitlements.dart';
import '../storage/secure_store.dart';

/// 兑换码输入:大写、去空格。
class _CodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text.toUpperCase().replaceAll(' ', '');
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// 会员页:权益对比表 + 会员信息卡片 + 兑换码弹窗。
/// 未登录(guest)仍显示权益对比表,不显示会员卡片,兑换时提示先登录。
class MembershipPage extends StatefulWidget {
  const MembershipPage({super.key});

  @override
  State<MembershipPage> createState() => _MembershipPageState();
}

class _MembershipPageState extends State<MembershipPage> {
  final _store = SecureStore();

  bool _loading = true;
  bool _hasJwt = false;
  Map<String, dynamic> _user = const {};
  String? _tier;
  String? _memberExpiresAt;

  /// 本月通知用量;加载失败置 null → 静默隐藏区块。
  Map<String, dynamic>? _usage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null || jwt.isEmpty) {
        setState(() {
          _hasJwt = false;
          _loading = false;
        });
        return;
      }
      final api = await ApiConfig.client();
      final me = await api.me(jwt);
      final user = me['user'] as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _hasJwt = true;
        _user = user;
        _tier = user['tier']?.toString();
        _memberExpiresAt = user['member_expires_at']?.toString();
        _loading = false;
      });
      // 通知用量:失败静默忽略(区块不显示)。
      try {
        final usage = await api.getNotificationUsage(jwt);
        if (mounted) setState(() => _usage = usage);
      } catch (_) {}
    } catch (_) {
      // 网络失败:仍展示权益对比表,会员卡片按未知处理。
      if (!mounted) return;
      setState(() {
        _hasJwt = true;
        _loading = false;
      });
    }
  }

  bool get _isMember => _tier == 'member';

  /// 解析到期时间:空串=永久;无时区标记视为 UTC(后端契约)。
  DateTime? _parseExpiry(String s) {
    if (s.isEmpty) return null;
    var t = s.trim();
    final hasZone = t.endsWith('Z') ||
        t.endsWith('z') ||
        RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(t);
    if (!hasZone) t = '${t.replaceFirst(' ', 'T')}Z';
    return DateTime.tryParse(t)?.toLocal();
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String _fmt(DateTime dt) =>
      '${dt.year}-${_two(dt.month)}-${_two(dt.day)} ${_two(dt.hour)}:${_two(dt.minute)}';

  String _fmtRemaining(Duration d) {
    if (d.isNegative) return L10n.tr('已到期');
    // 天数向上取整:到期时间点是当天某时刻,30 天兑换码在任意时刻查看都应显示 30 天,
    // 直到真正跨过到期日才减为 29 天。inDays 向下取整会在兑换后几小时就显示 29 天。
    final days = (d.inMinutes + 1439) ~/ 1440;
    if (days >= 1) return L10n.trp('{days} 天', {'days': '$days'});
    if (d.inHours >= 1) {
      return L10n.trp('{hours} 小时', {'hours': '${d.inHours}'});
    }
    return L10n.trp('{minutes} 分钟', {'minutes': '${d.inMinutes}'});
  }

  /// 会员信息卡片(仅会员显示)。
  Widget _memberCard() {
    final username = _user['username']?.toString() ?? '';
    final expiresAt = _memberExpiresAt ?? '';
    final isPermanent = expiresAt.isEmpty;
    final expiry = _parseExpiry(expiresAt);
    final remaining = expiry?.difference(DateTime.now());
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.workspace_premium, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  L10n.tr('会员'),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _infoRow(L10n.tr('用户名'), username),
            _infoRow(
              L10n.tr('到期时间'),
              isPermanent ? L10n.tr('永久') : _fmt(expiry!),
            ),
            _infoRow(
              L10n.tr('剩余时长'),
              isPermanent ? L10n.tr('永久有效') : _fmtRemaining(remaining!),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 80,
              child: Text(
                label,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer
                      .withValues(alpha: 0.7),
                ),
              ),
            ),
            Expanded(
              child: Text(
                value,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );

  /// 对比标记:免费列(muted)统一灰调(有=灰勾,无=灰叉),会员列绿勾。
  Widget _mark(bool ok, {bool muted = false}) => Icon(
        ok ? Icons.check_circle : Icons.remove_circle_outline,
        size: 18,
        color: (ok && !muted) ? Colors.green : Colors.grey,
      );

  /// 权益对比表(权益/免费/会员)。
  Widget _benefitTable() {
    final scheme = Theme.of(context).colorScheme;
    final labelStyle =
        TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: scheme.onSurface);
    final cellStyle = TextStyle(fontSize: 13, color: scheme.onSurface);
    // 会员列浅色底,突出"会员更好"。
    final memberTint = scheme.primary.withValues(alpha: 0.06);
    // 行间 1px 细分隔线。
    final divider =
        Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)));

    // (权益图标, 权益名, 免费列, 会员列)。
    final rows = <(IconData, String, Widget, Widget)>[
      (
        Icons.inventory_2,
        L10n.tr('资产数量'),
        Text(
          L10n.trp('{limit} 条', {'limit': '${Entitlements.free.assetLimit}'}),
        ),
        Text(L10n.tr('不限')),
      ),
      (
        Icons.cloud_sync,
        L10n.tr('云端同步'),
        _mark(Entitlements.free.cloudSync, muted: true),
        _mark(Entitlements.member.cloudSync),
      ),
      (
        Icons.family_restroom,
        L10n.tr('继承交接'),
        _mark(Entitlements.free.inheritance, muted: true),
        _mark(Entitlements.member.inheritance),
      ),
      (
        Icons.notifications,
        L10n.tr('通知渠道'),
        Text(L10n.tr('邮件+IM')),
        Text(L10n.tr('邮件+IM+短信')),
      ),
      (
        Icons.article,
        L10n.tr('自定义提醒模板'),
        _mark(false, muted: true),
        _mark(true),
      ),
      (
        Icons.table_chart,
        L10n.tr('Excel 导出'),
        _mark(false, muted: true),
        _mark(true),
      ),
      (
        Icons.cloud_off,
        L10n.tr('离线模式'),
        _mark(Entitlements.free.offlineMode, muted: true),
        _mark(Entitlements.member.offlineMode),
      ),
    ];

    // 单元格:内容居中,会员列加浅色底。
    Widget cell(Widget child, {bool tint = false}) => Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          color: tint ? memberTint : null,
          child: Align(
            alignment: Alignment.center,
            child: DefaultTextStyle(style: cellStyle, child: child),
          ),
        );

    // 表头"会员":主色 pill + 图标 + 高对比字。
    final memberPill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.workspace_premium, size: 14, color: scheme.onPrimary),
          const SizedBox(width: 4),
          Text(
            L10n.tr('会员'),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: scheme.onPrimary,
            ),
          ),
        ],
      ),
    );

    // 表头普通单元格:次级色。
    Widget headerCell(String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Align(
            alignment: Alignment.center,
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Table(
          columnWidths: const {
            0: FlexColumnWidth(1.4),
            1: FlexColumnWidth(1),
            2: FlexColumnWidth(1.4),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          children: [
            // 表头:免费普通样式,会员主色 pill。
            TableRow(
              decoration: BoxDecoration(color: scheme.surfaceContainerHighest),
              children: [
                headerCell(L10n.tr('权益')),
                headerCell(L10n.tr('免费')),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Align(alignment: Alignment.center, child: memberPill),
                ),
              ],
            ),
            // 数据行:隔行浅底 + 细分隔线,会员列 tint。
            for (final (i, (icon, label, free, member)) in rows.indexed)
              TableRow(
                decoration: BoxDecoration(
                  color: i.isOdd ? scheme.surfaceContainerLow : null,
                  border: divider,
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                    child: Row(
                      children: [
                        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Expanded(child: Text(label, style: labelStyle)),
                      ],
                    ),
                  ),
                  cell(free),
                  cell(member, tint: true),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 本月通知用量区块:邮件 + 短信(短信额度为 0 时隐藏,如免费用户)。
  Widget _usageCard() {
    final usage = _usage;
    if (usage == null) return const SizedBox.shrink();
    final emailUsed = (usage['email_used'] as num?)?.toInt() ?? 0;
    final emailLimit = (usage['email_limit'] as num?)?.toInt() ?? 0;
    final smsUsed = (usage['sms_used'] as num?)?.toInt() ?? 0;
    final smsLimit = (usage['sms_limit'] as num?)?.toInt() ?? 0;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.notifications_outlined, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  L10n.tr('本月通知用量'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _usageRow(
              icon: Icons.mail_outline,
              label: L10n.tr('邮件'),
              used: emailUsed,
              limit: emailLimit,
            ),
            // 短信额度为 0(免费用户)时不展示。
            if (smsLimit > 0) ...[
              const SizedBox(height: 12),
              _usageRow(
                icon: Icons.sms_outlined,
                label: L10n.tr('短信'),
                used: smsUsed,
                limit: smsLimit,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 单条用量:已用 X / 额度 Y + 进度条(额度为 0 时进度条 0)。
  Widget _usageRow({
    required IconData icon,
    required String label,
    required int used,
    required int limit,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final ratio = limit > 0 ? (used / limit).clamp(0.0, 1.0) : 0.0;
    return Row(
      children: [
        Icon(icon, size: 20, color: scheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(label, style: const TextStyle(fontSize: 14)),
                  const Spacer(),
                  Text(
                    L10n.trp('已用 {used} / {limit}', {
                      'used': '$used',
                      'limit': '$limit',
                    }),
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 6,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showRedeemDialog() async {
    if (!_hasJwt) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.tr('请先登录'))),
      );
      return;
    }
    final controller = TextEditingController();
    var submitting = false;

    Future<void> redeem(BuildContext ctx, StateSetter setDialogState) async {
      final code = controller.text.trim();
      if (!RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(code)) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text(L10n.tr('兑换码格式不正确'))),
        );
        return;
      }
      setDialogState(() => submitting = true);
      try {
        final jwt = await _store.readJwt();
        if (jwt == null || jwt.isEmpty) throw ApiException('请先登录');
        final api = await ApiConfig.client();
        await api.redeemMembership(jwt, code);
        if (!ctx.mounted) return;
        Navigator.of(ctx).pop();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.tr('兑换成功'))),
        );
        await _load();
      } on ApiException catch (e) {
        if (!ctx.mounted) return;
        setDialogState(() => submitting = false);
        ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(e.message)));
      } catch (_) {
        if (!ctx.mounted) return;
        setDialogState(() => submitting = false);
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text(L10n.tr('兑换失败,请检查网络'))),
        );
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(L10n.tr('兑换会员')),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [_CodeFormatter()],
            decoration: InputDecoration(
              labelText: L10n.tr('兑换码'),
              hintText: 'XXXX-XXXX-XXXX',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(L10n.tr('取消')),
            ),
            submitting
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : FilledButton(
                    onPressed: () => redeem(ctx, setDialogState),
                    child: Text(L10n.tr('兑换')),
                  ),
          ],
        ),
      ),
    );
    controller.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(L10n.tr('会员')),
        actions: [
          TextButton.icon(
            onPressed: _showRedeemDialog,
            icon: const Icon(Icons.card_giftcard),
            label: Text(L10n.tr('兑换')),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_isMember) ...[
                  _memberCard(),
                  const SizedBox(height: 16),
                ],
                _benefitTable(),
                // 通知用量:仅登录且有数据时展示,失败静默隐藏。
                if (_hasJwt && _usage != null) ...[
                  const SizedBox(height: 16),
                  _usageCard(),
                ],
              ],
            ),
    );
  }
}
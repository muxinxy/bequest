import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
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
    if (d.isNegative) return '已到期';
    // 天数向上取整:到期时间点是当天某时刻,30 天兑换码在任意时刻查看都应显示 30 天,
    // 直到真正跨过到期日才减为 29 天。inDays 向下取整会在兑换后几小时就显示 29 天。
    final days = (d.inMinutes + 1439) ~/ 1440;
    if (days >= 1) return '$days 天';
    if (d.inHours >= 1) return '${d.inHours} 小时';
    return '${d.inMinutes} 分钟';
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
                  '会员',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _infoRow('用户名', username),
            _infoRow('到期时间', isPermanent ? '永久' : _fmt(expiry!)),
            _infoRow(
              '剩余时长',
              isPermanent ? '永久有效' : _fmtRemaining(remaining!),
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

  /// ✓ 绿色 check / ✗ 灰色 close。
  Widget _mark(bool ok) => Icon(
        ok ? Icons.check_circle : Icons.cancel,
        size: 18,
        color: ok ? Colors.green : Colors.grey,
      );

  /// 权益对比表(权益/免费/会员)。
  Widget _benefitTable() {
    final rows = <(String, Widget, Widget)>[
      (
        '资产数量',
        Text('${Entitlements.free.assetLimit} 条'),
        const Text('不限'),
      ),
      ('云端同步', _mark(Entitlements.free.cloudSync), _mark(Entitlements.member.cloudSync)),
      ('继承交接', _mark(Entitlements.free.inheritance), _mark(Entitlements.member.inheritance)),
      (
        '通知渠道',
        const Text('邮件+IM'),
        const Text('邮件+IM+短信'),
      ),
      ('自定义提醒模板', _mark(false), _mark(true)),
      ('Excel 导出', _mark(false), _mark(true)),
      ('离线模式', _mark(Entitlements.free.offlineMode), _mark(Entitlements.member.offlineMode)),
    ];
    final scheme = Theme.of(context).colorScheme;
    final headerStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.bold,
      color: scheme.onSurfaceVariant,
    );
    final cellStyle = TextStyle(fontSize: 13, color: scheme.onSurface);
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
            TableRow(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Align(alignment: Alignment.center, child: Text('权益', style: headerStyle)),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Align(alignment: Alignment.center, child: Text('免费', style: headerStyle)),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Align(alignment: Alignment.center, child: Text('会员', style: headerStyle)),
                ),
              ],
            ),
            for (final (label, free, member) in rows)
              TableRow(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(label, style: cellStyle),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: DefaultTextStyle(
                      style: cellStyle,
                      child: Align(alignment: Alignment.center, child: free),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: DefaultTextStyle(
                      style: cellStyle,
                      child: Align(alignment: Alignment.center, child: member),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRedeemDialog() async {
    if (!_hasJwt) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先登录')),
      );
      return;
    }
    final controller = TextEditingController();
    var submitting = false;

    Future<void> redeem(BuildContext ctx, StateSetter setDialogState) async {
      final code = controller.text.trim();
      if (!RegExp(r'^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$').hasMatch(code)) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(content: Text('兑换码格式不正确')),
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
          const SnackBar(content: Text('兑换成功')),
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
          const SnackBar(content: Text('兑换失败,请检查网络')),
        );
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('兑换会员'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [_CodeFormatter()],
            decoration: const InputDecoration(
              labelText: '兑换码',
              hintText: 'XXXX-XXXX-XXXX',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
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
                    child: const Text('兑换'),
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
        title: const Text('会员'),
        actions: [
          TextButton.icon(
            onPressed: _showRedeemDialog,
            icon: const Icon(Icons.card_giftcard),
            label: const Text('兑换'),
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
              ],
            ),
    );
  }
}
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../storage/secure_store.dart';
import '../utils/validation.dart';

/// 通知渠道:邮箱/手机号各最多 3 个,整体替换保存。
/// 手机号为会员专属:免费用户输入框置灰禁用。
class NotificationChannelsPage extends StatefulWidget {
  const NotificationChannelsPage({super.key});

  @override
  State<NotificationChannelsPage> createState() =>
      _NotificationChannelsPageState();
}

class _NotificationChannelsPageState extends State<NotificationChannelsPage> {
  final _store = SecureStore();
  final List<TextEditingController> _emailControllers = [];
  final List<TextEditingController> _phoneControllers = [];

  bool _loading = true;
  bool _saving = false;

  /// 当前用户 tier(free/member);null 按免费处理。
  String? _tier;

  bool get _isMember => _tier == 'member';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _emailControllers) {
      c.dispose();
    }
    for (final c in _phoneControllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final api = await ApiConfig.client();
      final channels = await api.getNotificationChannels(jwt);
      final me = await api.me(jwt);
      final tier = (me['user'] as Map<String, dynamic>?)?['tier'] as String?;
      if (!mounted) return;
      setState(() {
        _tier = tier;
        _emailControllers
          ..clear()
          ..addAll([
            for (final e in (channels['emails'] as List? ?? const []))
              TextEditingController(text: e.toString()),
          ]);
        _phoneControllers
          ..clear()
          ..addAll([
            for (final p in (channels['phones'] as List? ?? const []))
              TextEditingController(text: p.toString()),
          ]);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加载失败,请检查网络后重试')),
      );
      Navigator.of(context).pop();
    }
  }

  void _addEmail() {
    if (_emailControllers.length >= 3) return;
    setState(() => _emailControllers.add(TextEditingController()));
  }

  void _removeEmail(int index) {
    setState(() => _emailControllers.removeAt(index).dispose());
  }

  void _addPhone() {
    if (_phoneControllers.length >= 3) return;
    setState(() => _phoneControllers.add(TextEditingController()));
  }

  void _removePhone(int index) {
    setState(() => _phoneControllers.removeAt(index).dispose());
  }

  Future<void> _save() async {
    final emails = _emailControllers
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final phones = _phoneControllers
        .map((c) => c.text.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    for (final e in emails) {
      if (!isValidEmail(e)) {
        _show('邮箱格式不正确');
        return;
      }
    }
    for (final p in phones) {
      if (!isValidPhone(p)) {
        _show('手机号格式不正确(5-20 位数字)');
        return;
      }
    }
    if (phones.isNotEmpty && !_isMember) {
      _show('手机号功能为会员专属');
      return;
    }
    setState(() => _saving = true);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      await (await ApiConfig.client()).putNotificationChannels(
        jwt,
        emails: emails,
        phones: phones,
      );
      _show('已保存');
    } on ApiException catch (e) {
      _show(e.message);
    } catch (_) {
      _show('保存失败,请检查网络后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知渠道')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionHeader(
                  context,
                  '邮箱',
                  '未设置邮箱时默认使用注册邮箱',
                  onAdd: _emailControllers.length >= 3 ? null : _addEmail,
                ),
                for (var i = 0; i < _emailControllers.length; i++)
                  _channelField(
                    controller: _emailControllers[i],
                    hint: 'name@example.com',
                    keyboardType: TextInputType.emailAddress,
                    onDelete: () => _removeEmail(i),
                  ),
                const SizedBox(height: 24),
                _sectionHeader(
                  context,
                  '手机号',
                  _isMember ? '最多 3 个,用于短信提醒' : '会员专属,升级后可用',
                  onAdd: _isMember && _phoneControllers.length < 3
                      ? _addPhone
                      : null,
                  memberOnly: !_isMember,
                ),
                for (var i = 0; i < _phoneControllers.length; i++)
                  _channelField(
                    controller: _phoneControllers[i],
                    hint: '13800138000',
                    keyboardType: TextInputType.phone,
                    enabled: _isMember,
                    onDelete: _isMember ? () => _removePhone(i) : null,
                  ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? '保存中...' : '保存'),
                ),
              ],
            ),
    );
  }

  /// 分区标题 + 添加按钮;手机号非会员时置灰并标注「会员专属」。
  Widget _sectionHeader(
    BuildContext context,
    String title,
    String hint, {
    VoidCallback? onAdd,
    bool memberOnly = false,
  }) {
    final color = memberOnly ? Colors.grey : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                    if (memberOnly) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '会员专属',
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  hint,
                  style: TextStyle(fontSize: 12, color: color ?? Colors.grey),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '添加$title',
            icon: Icon(Icons.add_circle_outline, color: color),
            onPressed: onAdd,
          ),
        ],
      ),
    );
  }

  Widget _channelField({
    required TextEditingController controller,
    required String hint,
    required TextInputType keyboardType,
    VoidCallback? onDelete,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              keyboardType: keyboardType,
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
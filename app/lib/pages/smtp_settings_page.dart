import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../l10n/app_l10n.dart';
import '../storage/secure_store.dart';

/// 邮箱发件设置页:调用后端 /api/v1/settings/smtp 保存自定义 SMTP 凭据。
/// 凭据仅加密保存在服务端,邮件由用户自己的邮箱直接发送。
class SmtpSettingsPage extends StatefulWidget {
  const SmtpSettingsPage({super.key});

  @override
  State<SmtpSettingsPage> createState() => _SmtpSettingsPageState();
}

class _SmtpSettingsPageState extends State<SmtpSettingsPage> {
  final _store = SecureStore();

  /// 按当前配置构造客户端(走用户配置的服务器地址,而非默认地址)。
  late final Future<ApiClient> _api = ApiConfig.client();

  final _host = TextEditingController();
  final _port = TextEditingController(text: '587');
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _fromAddr = TextEditingController();
  bool _enabled = false;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_host, _port, _user, _password, _fromAddr]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final jwt = await _store.readJwt();
    if (jwt == null) {
      _snack(L10n.tr('登录状态已失效,请重新登录'));
      setState(() => _loading = false);
      return;
    }
    try {
      // 超时兜底:服务器不可达时结束加载,避免页面一直转圈。
      final cfg = await (await _api)
          .getSmtpSettings(jwt)
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() {
        _host.text = cfg['host']?.toString() ?? '';
        final port = (cfg['port'] as num?)?.toInt();
        if (port != null) _port.text = '$port';
        _user.text = cfg['user']?.toString() ?? '';
        _fromAddr.text = cfg['from_addr']?.toString() ?? '';
        _enabled = cfg['enabled'] == true;
        _loading = false;
      });
    } catch (_) {
      // 后端未就绪/超时:保留默认值,页面仍可编辑。
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final jwt = await _store.readJwt();
    if (jwt == null) {
      _snack(L10n.tr('登录状态已失效,请重新登录'));
      return;
    }
    final body = <String, dynamic>{
      'host': _host.text.trim(),
      'port': int.tryParse(_port.text.trim()) ?? 587,
      'user': _user.text.trim(),
      'from_addr': _fromAddr.text.trim(),
      'enabled': _enabled,
      // 密码留空 = 保持现有凭据。
      if (_password.text.isNotEmpty) 'password': _password.text,
    };
    setState(() => _saving = true);
    try {
      await (await _api)
          .updateSmtpSettings(jwt, body)
          .timeout(const Duration(seconds: 5));
      _snack(L10n.tr('已保存'));
    } catch (_) {
      _snack(L10n.tr('保存失败,请检查网络后重试'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L10n.tr('清除发件设置')),
        content: Text(L10n.tr('确定清除自定义 SMTP 设置吗?之后将恢复使用托孤服务端发送。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.tr('清除')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final jwt = await _store.readJwt();
    if (jwt == null) {
      _snack(L10n.tr('登录状态已失效,请重新登录'));
      return;
    }
    try {
      await (await _api)
          .deleteSmtpSettings(jwt)
          .timeout(const Duration(seconds: 5));
      if (!mounted) return;
      setState(() {
        _host.clear();
        _port.text = '587';
        _user.clear();
        _password.clear();
        _fromAddr.clear();
        _enabled = false;
      });
      _snack(L10n.tr('已清除发件设置'));
    } catch (_) {
      _snack(L10n.tr('清除失败,请检查网络后重试'));
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.tr('邮箱发件设置'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  L10n.tr(
                    '提醒邮件将优先使用您自己的邮箱发送,不经过托孤服务端'
                    '(服务端仅加密保存凭据)。',
                  ),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 16),
                _field(_host, L10n.tr('服务器'), hint: 'smtp.example.com'),
                _field(_port, L10n.tr('端口'), hint: '587'),
                _field(_user, L10n.tr('用户名')),
                _field(
                  _password,
                  L10n.tr('密码'),
                  hint: L10n.tr('留空表示保持现有密码'),
                  obscure: true,
                ),
                _field(_fromAddr, L10n.tr('发件地址'), hint: 'noreply@example.com'),
                SwitchListTile(
                  title: Text(L10n.tr('启用')),
                  subtitle: Text(L10n.tr('启用自定义邮箱发送提醒邮件')),
                  value: _enabled,
                  onChanged: (value) => setState(() => _enabled = value),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? L10n.tr('保存中...') : L10n.tr('保存')),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: _saving ? null : _clear,
                  child: Text(L10n.tr('清除设置')),
                ),
              ],
            ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

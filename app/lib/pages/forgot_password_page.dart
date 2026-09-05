import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../l10n/app_l10n.dart';

/// 忘记密码:输入邮箱 → 发送验证码 → 输入验证码与新密码重置。
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  late final Future<ApiClient> _api = ApiConfig.client();
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _sending = false;
  bool _submitting = false;

  /// 发送验证码冷却倒计时(秒):防重复点击刷接口。
  Timer? _cooldownTimer;
  int _cooldown = 0;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (!email.contains('@')) {
      _show(L10n.tr('请输入正确的邮箱'));
      return;
    }
    setState(() => _sending = true);
    try {
      await (await _api).requestPasswordReset(email);
      if (!mounted) return;
      _show(L10n.tr('验证码已发送到邮箱(10 分钟内有效)'));
      _startCooldown();
    } catch (_) {
      _show(L10n.tr('发送失败,请检查网络后重试'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 发送成功后进入 60 秒冷却:按钮禁用并显示剩余秒数。
  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _cooldown = 60);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _cooldown--);
      if (_cooldown <= 0) timer.cancel();
    });
  }

  String get _sendButtonLabel {
    if (_sending) return L10n.tr('发送中...');
    if (_cooldown > 0) return L10n.trp('重新发送({seconds} s)', {'seconds': '$_cooldown'});
    return L10n.tr('发送验证码');
  }

  Future<void> _reset() async {
    if (_passwordController.text.length < 8) {
      _show(L10n.tr('新密码至少 8 位'));
      return;
    }
    if (_passwordController.text != _confirmController.text) {
      _show(L10n.tr('两次输入的密码不一致'));
      return;
    }
    setState(() => _submitting = true);
    try {
      await (await _api).resetPassword(
        email: _emailController.text.trim(),
        code: _codeController.text.trim(),
        newPassword: _passwordController.text,
      );
      if (!mounted) return;
      _show(L10n.tr('密码已重置,请用新密码登录'));
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      _show(e.message);
    } catch (_) {
      _show(L10n.tr('重置失败,请检查网络后重试'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.tr('重置密码'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: L10n.tr('注册邮箱'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _codeController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: L10n.tr('验证码'),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: (_sending || _cooldown > 0) ? null : _sendCode,
                  child: Text(_sendButtonLabel),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: L10n.tr('新密码(至少 8 位)'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirmController,
              obscureText: true,
              decoration: InputDecoration(
                labelText: L10n.tr('确认新密码'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submitting ? null : _reset,
              child: Text(
                _submitting ? L10n.tr('重置中...') : L10n.tr('重置密码'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

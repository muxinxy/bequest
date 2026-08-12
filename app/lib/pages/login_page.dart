import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../storage/secure_store.dart';
import 'forgot_password_page.dart';
import 'home_page.dart';
import 'local_unlock_page.dart';
import 'register_page.dart';
import 'server_settings_page.dart';

/// 登录页:提交用户名与密码,成功后进入主页。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  late final Future<ApiClient> _api = ApiConfig.client();
  final _store = SecureStore();

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _captchaController = TextEditingController();

  bool _submitting = false;
  String _captchaId = '';
  String _captchaQuestion = '';

  @override
  void initState() {
    super.initState();
    _refreshCaptcha();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _captchaController.dispose();
    super.dispose();
  }

  /// 获取算术验证码(注册/登录共用;失败不阻塞,服务端校验兜底)。
  Future<void> _refreshCaptcha() async {
    try {
      final c = await (await _api).getCaptcha();
      if (mounted) {
        setState(() {
          _captchaId = c['captcha_id']?.toString() ?? '';
          _captchaQuestion = c['question']?.toString() ?? '';
          _captchaController.clear();
        });
      }
    } catch (_) {
      // 验证码获取失败:提交时服务端会要求验证码,提示用户重试。
      if (mounted) {
        setState(() {
          _captchaId = '';
          _captchaQuestion = '';
        });
      }
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      // 预检服务器可用性:不可达立即反馈,不等登录请求超时转圈。
      final api = await _api;
      if (!await _checkServer(api)) {
        if (!mounted) return;
        _showError('无法连接服务器,请检查网络或服务器地址');
        return;
      }
      final response = await api.login(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        captchaId: _captchaId,
        captcha: _captchaController.text.trim(),
      );
      final token = _extractJwt(response);
      await _store.saveJwt(token);
      // 登录即云端模式:避免沿用上次的本地模式设置。
      await _store.saveStorageMode('cloud');

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const HomePage()),
      );
    } on ApiException catch (e) {
      // 验证码错误/过期:刷新验证码让用户重试。
      if (e.message.contains('验证码')) await _refreshCaptcha();
      _showError(e.message);
    } catch (_) {
      _showError('登录失败,请检查网络后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 快速服务器可用性检查:GET /healthz,2 秒超时。
  Future<bool> _checkServer(ApiClient api) async {
    try {
      await api
          .checkServerHealth()
          .timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  String _extractJwt(Map<String, dynamic> response) {
    for (final key in const ['token', 'access_token', 'jwt']) {
      final value = response[key];
      if (value is String && value.isNotEmpty) return value;
    }
    throw ApiException('服务器未返回登录凭证');
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 64),
              const Icon(Icons.shield_outlined, size: 72),
              const SizedBox(height: 8),
              Text(
                '托孤',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              const Text(
                '数字资产安全传承',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 40),
              TextFormField(
                controller: _usernameController,
                decoration: const InputDecoration(
                  labelText: '用户名/邮箱',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? '请输入用户名或邮箱'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.isEmpty)
                    ? '请输入密码'
                    : null,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _captchaController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '验证码',
                        hintText: '输入算式答案',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          (value == null || value.trim().isEmpty)
                              ? '请输入验证码'
                              : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  InkWell(
                    onTap: _refreshCaptcha,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey.shade400),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _captchaQuestion.isEmpty ? '加载中' : _captchaQuestion,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _submitting ? null : _login,
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('登录'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const RegisterPage(),
                          ),
                        );
                      },
                child: const Text('还没有账号?去注册'),
              ),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ForgotPasswordPage(),
                          ),
                        );
                      },
                child: const Text('忘记密码', style: TextStyle(color: Colors.grey)),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _submitting
                    ? null
                    : () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const LocalUnlockPage(),
                          ),
                        );
                      },
                child: const Text('进入本地模式'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ServerSettingsPage(),
                          ),
                        );
                      },
                child: const Text(
                  '服务器设置',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

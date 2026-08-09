import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../storage/secure_store.dart';
import 'home_page.dart';
import 'local_unlock_page.dart';
import 'register_page.dart';
import 'server_settings_page.dart';
import 'sync_settings_page.dart';

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

  bool _submitting = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final response = await (await _api).login(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
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
      _showError(e.message);
    } catch (_) {
      _showError('登录失败,请检查网络后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
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
                  labelText: '用户名',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? '请输入用户名'
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
                            builder: (_) => const SyncSettingsPage(),
                          ),
                        );
                      },
                child: const Text(
                  '自托管同步(无需登录)',
                  style: TextStyle(color: Colors.grey),
                ),
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

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../crypto/key_derivation.dart';
import '../storage/secure_store.dart';
import 'home_page.dart';

/// 注册页:收集账号信息与主密码,派生并包装主密钥后提交后端。
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _api = ApiClient();
  final _store = SecureStore();

  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _masterPasswordController = TextEditingController();
  final _masterPasswordConfirmController = TextEditingController();

  bool _submitting = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _masterPasswordController.dispose();
    _masterPasswordConfirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final salt = generateSalt();
      final masterKey = deriveMasterKey(
        _masterPasswordController.text,
        salt,
      );
      final wrappingKey = generateWrappingKey();
      final wrapped = wrapMasterKey(masterKey, wrappingKey);

      final response = await _api.register(
        username: _usernameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
        masterKeyWrapped: wrapped,
      );

      await _store.saveJwt(_extractJwt(response));
      await _store.saveMasterKey(masterKey);
      await _store.saveWrappingKey(wrappingKey);

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const HomePage()),
      );
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('注册失败,请检查网络后重试');
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
      appBar: AppBar(title: const Text('注册')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: '邮箱',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return '请输入邮箱';
                  if (!value.contains('@')) return '邮箱格式不正确';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '登录密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.length < 8)
                    ? '密码至少 8 位'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _masterPasswordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '主密码',
                  helperText: '用于加密您的资产数据,请务必牢记',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.length < 8)
                    ? '主密码至少 8 位'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _masterPasswordConfirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '确认主密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value != _masterPasswordController.text ? '两次输入的主密码不一致' : null,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('注册'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

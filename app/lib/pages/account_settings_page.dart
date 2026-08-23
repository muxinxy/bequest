import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../storage/secure_store.dart';
import '../utils/validation.dart';
import 'login_page.dart';

/// 账号信息:修改用户名/邮箱 + 修改登录密码。
class AccountSettingsPage extends StatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  State<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends State<AccountSettingsPage> {
  final _store = SecureStore();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();

  // 修改密码
  final _pwFormKey = GlobalKey<FormState>();
  final _currentPwController = TextEditingController();
  final _newPwController = TextEditingController();
  final _confirmPwController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _changingPw = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _currentPwController.dispose();
    _newPwController.dispose();
    _confirmPwController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) return;
      final me = await (await ApiConfig.client()).me(jwt);
      final user = me['user'] as Map<String, dynamic>? ?? const {};
      if (mounted) {
        setState(() {
          _usernameController.text = user['username']?.toString() ?? '';
          _emailController.text = user['email']?.toString() ?? '';
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final username = _usernameController.text.trim();
    final email = _emailController.text.trim();
    if (username.isEmpty || email.isEmpty) {
      _show('用户名和邮箱不能为空');
      return;
    }
    if (!isValidEmail(email)) {
      _show('邮箱格式不正确');
      return;
    }
    setState(() => _saving = true);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      await (await ApiConfig.client()).updateProfile(jwt, {
        'username': username,
        'email': email,
      });
      _show('已保存');
    } on ApiException catch (e) {
      _show(e.statusCode == 409 ? '用户名或邮箱已被占用' : e.message);
    } catch (_) {
      _show('保存失败,请检查网络后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 修改登录密码:成功后旧 token 已失效,清凭据回登录页重新登录。
  Future<void> _changePassword() async {
    if (!_pwFormKey.currentState!.validate()) return;
    setState(() => _changingPw = true);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      await (await ApiConfig.client()).changePassword(
        jwt,
        _currentPwController.text,
        _newPwController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码已修改,请重新登录')),
      );
      await _store.clearAll();
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const LoginPage()),
        (route) => false,
      );
    } on ApiException catch (e) {
      _show(e.statusCode == 401 ? '当前密码错误' : e.message);
    } catch (_) {
      _show('修改失败,请检查网络后重试');
    } finally {
      if (mounted) setState(() => _changingPw = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('账号信息')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      helperText: '3-20 位字母/数字/下划线,登录时可用',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: '邮箱',
                      helperText: '登录与找回密码使用',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '保存中...' : '保存'),
                  ),
                  const SizedBox(height: 32),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text(
                    '修改登录密码',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '修改后所有已登录设备将退出,需重新登录',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 16),
                  Form(
                    key: _pwFormKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: _currentPwController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: '当前密码',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) =>
                              (value == null || value.isEmpty) ? '请输入当前密码' : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _newPwController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: '新密码',
                            helperText: '至少 8 位',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) => (value == null || value.length < 8)
                              ? '新密码至少 8 位'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _confirmPwController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: '确认新密码',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) => value != _newPwController.text
                              ? '两次输入的新密码不一致'
                              : null,
                        ),
                        const SizedBox(height: 20),
                        FilledButton.tonal(
                          onPressed: _changingPw ? null : _changePassword,
                          child: Text(_changingPw ? '修改中...' : '确认修改密码'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

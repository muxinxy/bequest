import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../crypto/reset_master_password.dart';
import '../storage/secure_store.dart';

/// 忘记主密码 → 用账户密码重置。
///
/// 端到端加密的固有代价:**旧敏感数据(凭据/备注)不可恢复**——重置后资产
/// 保留名称/分类/到期日,凭据清空需重新填写。本地模式无账户密码,不可用。
class ResetMasterPasswordPage extends StatefulWidget {
  const ResetMasterPasswordPage({super.key});

  @override
  State<ResetMasterPasswordPage> createState() =>
      _ResetMasterPasswordPageState();
}

class _ResetMasterPasswordPageState extends State<ResetMasterPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _store = SecureStore();

  final _accountPasswordController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  final _hintController = TextEditingController();

  bool _submitting = false;

  @override
  void dispose() {
    _accountPasswordController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    _hintController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认重置主密码?'),
        content: const Text(
          '重置后将无法解密现有的资产凭据与备注(端到端加密),'
          '资产将保留名称/分类,凭据需重新填写。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认重置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _submitting = true);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null || jwt.isEmpty) {
        _showMessage('本地模式无账户密码,无法重置主密码(请重新设置本地库)');
        return;
      }
      final api = await ApiConfig.client();
      final result = await resetMasterPassword(
        store: _store,
        api: api,
        jwt: jwt,
        accountPassword: _accountPasswordController.text,
        newPassword: _newController.text,
        newHint: _hintController.text.trim(),
      );
      if (!mounted) return;
      if (!result.ok) {
        _showMessage(result.error ?? '重置失败');
        return;
      }
      _showMessage('主密码已重置');
      _accountPasswordController.clear();
      _newController.clear();
      _confirmController.clear();
      _hintController.clear();
    } on ApiException catch (e) {
      _showMessage(e.statusCode == 401 ? '账户密码错误' : '重置失败,请检查网络后重试');
    } catch (_) {
      _showMessage('重置失败,请检查网络后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('重置主密码')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '忘记主密码时,用账户密码重置。'
                '端到端加密意味着旧数据不可恢复:重置后资产保留名称/分类,'
                '凭据与备注清空,需重新填写。',
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _accountPasswordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '账户密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.isEmpty)
                    ? '请输入账户密码'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _newController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '新主密码',
                  helperText: '至少 8 位,用于加密本地数据',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.length < 8)
                    ? '新主密码至少 8 位'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '确认新主密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value != _newController.text
                    ? '两次输入不一致'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _hintController,
                decoration: const InputDecoration(
                  labelText: '主密码提示语(可选)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                child: Text(_submitting ? '重置中...' : '重置主密码'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

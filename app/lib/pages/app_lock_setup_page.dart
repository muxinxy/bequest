import 'package:flutter/material.dart';

import '../crypto/key_derivation.dart';
import '../crypto/pin_hash.dart';
import '../storage/secure_store.dart';

/// 锁设置:设置/修改 PIN(4-6 位)并开关生物识别解锁。
class AppLockSetupPage extends StatefulWidget {
  const AppLockSetupPage({super.key});

  @override
  State<AppLockSetupPage> createState() => _AppLockSetupPageState();
}

class _AppLockSetupPageState extends State<AppLockSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _store = SecureStore();

  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _biometric = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final biometric = await _store.readLockBiometric();
      if (mounted) setState(() => _biometric = biometric);
    } catch (_) {
      // 读取失败按默认处理。
    }
  }

  String? _validatePin(String? value) {
    if (value == null || value.isEmpty) return '请输入 PIN 码';
    if (!RegExp(r'^\d{4,6}$').hasMatch(value)) return 'PIN 码需为 4-6 位数字';
    return null;
  }

  String? _validateConfirm(String? value) {
    if (value != _pinController.text) return '两次输入的 PIN 码不一致';
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final pin = _pinController.text;
      final salt = generateSalt();
      await _store.savePinSalt(salt);
      await _store.savePinHash(hashPin(pin, salt));
      await _store.setLockEnabled(true);
      await _store.setLockBiometric(_biometric);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('应用锁已启用')));
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('保存失败,请重试')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('锁设置')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'PIN 码',
                  helperText: '4-6 位数字,用于解锁应用',
                  border: OutlineInputBorder(),
                ),
                validator: _validatePin,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: '确认 PIN 码',
                  border: OutlineInputBorder(),
                ),
                validator: _validateConfirm,
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('生物识别解锁'),
                subtitle: const Text('支持指纹或面容解锁'),
                value: _biometric,
                onChanged: (value) => setState(() => _biometric = value),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

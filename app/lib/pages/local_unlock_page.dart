import 'package:flutter/material.dart';

import '../crypto/key_derivation.dart';
import '../crypto/master_password.dart';
import '../storage/secure_store.dart';
import '../sync/local_vault.dart';
import 'home_page.dart';
import 'sync_settings_page.dart';

/// 本地模式入口形态。
enum LocalUnlockStep { setup, unlock }

/// 本地模式入口判定:已有主密钥 → 解锁;否则 → 设置主密码。
/// (抽成纯函数便于单元测试)
LocalUnlockStep localUnlockStep({required bool hasMasterKey}) =>
    hasMasterKey ? LocalUnlockStep.unlock : LocalUnlockStep.setup;

/// 进入本地模式(无需登录):首次设置主密码,之后用主密码解锁。
class LocalUnlockPage extends StatefulWidget {
  const LocalUnlockPage({super.key});

  @override
  State<LocalUnlockPage> createState() => _LocalUnlockPageState();
}

class _LocalUnlockPageState extends State<LocalUnlockPage> {
  final _store = SecureStore();
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  LocalUnlockStep _step = LocalUnlockStep.setup;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final mk = await _store.readMasterKey();
    if (!mounted) return;
    setState(() {
      _step = localUnlockStep(hasMasterKey: mk != null && mk.isNotEmpty);
    });
  }

  Future<void> _setupMasterPassword() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final salt = generateSalt();
      final mk = deriveMasterKey(_passwordController.text, salt);
      await _store.saveMasterSalt(salt);
      await _store.saveMasterKey(mk);
      // 初始化空本地库(携带 salt,供跨设备恢复)。
      await LocalVault().saveLocalData(
        {
          'schema': 1,
          'assets': <Map<String, dynamic>>[],
          'categories': <Map<String, dynamic>>[],
        },
        mk,
        salt: salt,
      );
      await _store.saveStorageMode('local');
      _enterLocalHome();
    } catch (_) {
      _showError('设置主密码失败,请重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _unlock() async {
    if (!await verifyMasterPassword(_passwordController.text)) {
      _showError('主密码错误');
      return;
    }
    await _store.saveStorageMode('local');
    _enterLocalHome();
  }

  void _enterLocalHome() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const HomePage()),
    );
  }

  Future<void> _goRestore() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SyncSettingsPage()),
    );
    // 恢复流程可能已写入主密钥,重新判定入口形态。
    await _init();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final isSetup = _step == LocalUnlockStep.setup;
    return Scaffold(
      appBar: AppBar(title: const Text('进入本地模式')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.offline_pin_outlined, size: 64),
              const SizedBox(height: 8),
              Text(
                isSetup ? '设置主密码' : '输入主密码解锁',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              const Text(
                '本地模式无需登录,数据加密保存在本机',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: '主密码',
                  helperText: isSetup ? '至少 8 位,用于加密本地数据' : null,
                  border: const OutlineInputBorder(),
                ),
                validator: (value) =>
                    (value == null || value.length < 8) ? '主密码至少 8 位' : null,
              ),
              if (isSetup) ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _confirmController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '确认主密码',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => value != _passwordController.text
                      ? '两次输入的主密码不一致'
                      : null,
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _submitting
                    ? null
                    : (isSetup ? _setupMasterPassword : _unlock),
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(isSetup ? '设置并进入' : '解锁'),
              ),
              if (isSetup) ...[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _submitting ? null : _goRestore,
                  child: const Text(
                    '从备份恢复(需主密码)',
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

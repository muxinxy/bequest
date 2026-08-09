import 'package:flutter/material.dart';

import '../crypto/key_derivation.dart';
import '../storage/secure_store.dart';
import '../sync/local_vault.dart';
import 'home_page.dart';
import 'sync_settings_page.dart';

/// 本地模式入口形态。
enum LocalUnlockStep { setup, unlock }

/// 本地模式入口判定:已有主密钥 → 直接进入(设备已受应用锁保护);
/// 否则 → 设置主密码。(抽成纯函数便于单元测试)
LocalUnlockStep localUnlockStep({required bool hasMasterKey}) =>
    hasMasterKey ? LocalUnlockStep.unlock : LocalUnlockStep.setup;

/// 进入本地模式(无需登录):首次设置主密码;之后由应用锁(PIN/图案/生物识别)
/// 保护本机,不再重复校验主密码,直接进入。
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
  final _hintController = TextEditingController();

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
    _hintController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final mk = await _store.readMasterKey();
    if (!mounted) return;
    final step = localUnlockStep(hasMasterKey: mk != null && mk.isNotEmpty);
    setState(() => _step = step);
    if (step == LocalUnlockStep.unlock) {
      // 已有主密钥:本机受应用锁保护,主密码重复校验冗余,直接进入。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _enterLocalHome();
      });
    }
  }

  Future<void> _setupMasterPassword() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final salt = generateSalt();
      final mk = deriveMasterKey(_passwordController.text, salt);
      await _store.saveMasterSalt(salt);
      await _store.saveMasterKey(mk);
      // 主密码提示语(可选):仅本机保存,帮助回忆,不随备份上传。
      final hint = _hintController.text.trim();
      if (hint.isNotEmpty) await _store.saveMasterHint(hint);
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

  Future<void> _enterLocalHome() async {
    if (!mounted) return;
    await _store.saveStorageMode('local');
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const HomePage()),
    );
  }

  Future<void> _goRestore() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SyncSettingsPage()));
    // 恢复流程可能已写入主密钥,重新判定入口形态。
    await _init();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_step == LocalUnlockStep.unlock) {
      return Scaffold(
        appBar: AppBar(title: const Text('进入本地模式')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('本机已设置主密码,直接进入本地模式'),
              ],
            ),
          ),
        ),
      );
    }
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
              const Text(
                '设置主密码',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
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
                decoration: const InputDecoration(
                  labelText: '主密码',
                  helperText: '至少 8 位,用于加密本地数据',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    (value == null || value.length < 8) ? '主密码至少 8 位' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '确认主密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value != _passwordController.text ? '两次输入的主密码不一致' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _hintController,
                maxLength: 50,
                decoration: const InputDecoration(
                  labelText: '主密码提示语(可选)',
                  hintText: '帮助回忆的提示,仅保存在本机',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _submitting ? null : _setupMasterPassword,
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('设置并进入'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _submitting ? null : _goRestore,
                child: const Text(
                  '从备份恢复(需主密码)',
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

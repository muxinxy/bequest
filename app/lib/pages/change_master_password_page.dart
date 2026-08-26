import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../crypto/asset_crypto.dart';
import '../crypto/attempt_guard.dart';
import '../crypto/key_derivation.dart';
import '../crypto/master_key_change.dart';
import '../crypto/master_password.dart';
import '../storage/secure_store.dart';
import '../sync/local_vault.dart';

/// 修改主密码(目前仅注册/本地模式首次设置时可设定):
/// 校验当前主密码 → 重加密本地库 → 更新本机密钥/盐/提示语 →
/// 已登录时同步新的云端继承密钥包装。
class ChangeMasterPasswordPage extends StatefulWidget {
  const ChangeMasterPasswordPage({super.key});

  @override
  State<ChangeMasterPasswordPage> createState() =>
      _ChangeMasterPasswordPageState();
}

class _ChangeMasterPasswordPageState extends State<ChangeMasterPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _store = SecureStore();
  final _oldController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  final _hintController = TextEditingController();
  final _accountPasswordController = TextEditingController();

  /// 主密码限流(与锁屏"用主密码解锁"共用同一计数)。
  late final AttemptGuard _masterGuard = AttemptGuard(
    store: _store,
    prefix: 'master',
  );

  bool _loggedIn = false;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _oldController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    _hintController.dispose();
    _accountPasswordController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final jwt = await _store.readJwt();
    String? hint;
    try {
      hint = await _store.readMasterHint();
    } catch (_) {
      // 插件缺失(测试环境)时忽略提示语。
    }
    if (!mounted) return;
    setState(() {
      _loggedIn = jwt != null && jwt.isNotEmpty;
      _hintController.text = hint ?? '';
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      // 先取旧主密钥:云端逐资产重包用。
      final oldMk = await _store.readMasterKey();
      final result = await changeMasterPasswordLocal(
        store: _store,
        vault: LocalVault(),
        verifyOld: (pw) =>
            guardedVerifyMasterPassword(context, _masterGuard, pw),
        oldPassword: _oldController.text,
        newPassword: _newController.text,
        newHint: _hintController.text.trim(),
      );
      if (!result.ok) {
        // 旧主密码校验失败时限流消息已由 guardedVerifyMasterPassword 提示。
        if (result.error != null) _showMessage(result.error!);
        return;
      }
      if (!mounted) return;
      // 新密码留空(仅改提示语):newMk == oldMk,无需云端重包,只提示。
      if (_newController.text.trim().isEmpty) {
        _showMessage('主密码提示语已更新');
        _clearSensitiveFields();
        return;
      }
      await _syncToCloud(result.newMk!, oldMk ?? '');
      _clearSensitiveFields();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 已登录:用新主密钥重新包装并同步云端;未登录/失败均不阻断本地更新。
  ///
  /// 除更新 master_key_wrapped 外,还必须逐资产用新 MK 重包
  /// asset_key_wrapped_mk(旧 MK 已不可用,否则改密后云端资产无法解密);
  /// 凭据密文与 asset_key_wrapped_wk 原样保留(非破坏性)。
  Future<void> _syncToCloud(String newMk, String oldMk) async {
    if (!_loggedIn) {
      _showMessage('已更新本地主密码');
      return;
    }
    final jwt = await _store.readJwt();
    if (jwt == null || jwt.isEmpty) {
      _showMessage('已更新本地主密码');
      return;
    }
    final wrappingKey = await _store.readWrappingKey();
    if (wrappingKey == null || wrappingKey.isEmpty) {
      _showMessage('云端同步失败,本地已更新');
      return;
    }
    final wrapped = wrapMasterKey(newMk, wrappingKey);
    try {
      final api = await ApiConfig.client();
      await api.updateMasterKeyWrapped(
        jwt,
        _accountPasswordController.text,
        wrapped,
      );
      // 同步新盐:否则服务端盐是旧的,新设备恢复会用旧盐派生 → 误报主密码错误。
      final newSalt = await _store.readMasterSalt();
      if (newSalt != null && newSalt.isNotEmpty) {
        await api.updateMasterSalt(jwt, newSalt);
      }
      // 逐资产用新 MK 重包 AK(旧 MK 已换,不重包则解不开)。
      if (oldMk.isNotEmpty) {
        final assets = await api.listAssets(jwt);
        for (final a in assets) {
          final id = '${a['id']}';
          try {
            final full = await api.getAsset(jwt, id);
            final wrappedMk = full['asset_key_wrapped_mk']?.toString() ?? '';
            if (wrappedMk.isEmpty) continue; // 老资产无 AK 包装,跳过
            final ak = unwrapAssetKey(wrappedMk, oldMk);
            await api.updateAsset(jwt, id, {
              'name': full['name']?.toString() ?? '',
              'asset_type': full['asset_type']?.toString() ?? 'physical',
              'category_id': full['category_id'],
              'expiry_date': full['expiry_date'],
              'encrypted_data': full['encrypted_data']?.toString() ?? '',
              'asset_key_wrapped_mk': wrapAssetKey(ak, newMk),
              'asset_key_wrapped_wk':
                  full['asset_key_wrapped_wk']?.toString() ?? '',
            });
          } catch (_) {
            // 单条失败不阻断整体(该资产旧包无法解开,可手动重加)。
          }
        }
      }
      _showMessage('云端已同步');
    } on ApiException catch (e) {
      _showMessage(
        e.statusCode == 401 ? '账户密码错误,云端继承密钥未更新' : '云端同步失败,本地已更新',
      );
    } catch (_) {
      _showMessage('云端同步失败,本地已更新');
    }
  }

  void _clearSensitiveFields() {
    _oldController.clear();
    _newController.clear();
    _confirmController.clear();
    _accountPasswordController.clear();
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
      appBar: AppBar(title: const Text('修改主密码')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _oldController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '当前主密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.isEmpty)
                    ? '请输入当前主密码'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _newController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '新主密码(留空则不修改)',
                  helperText: '留空仅更新提示语;填写则至少 8 位',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final v = value ?? '';
                  if (v.isEmpty) return null; // 留空 = 只改提示语
                  if (v.length < 8) return '新主密码至少 8 位';
                  if (v == _oldController.text) return '新主密码不能与当前相同';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '确认新主密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (_newController.text.isEmpty) return null; // 未改密码
                  return value != _newController.text ? '两次输入的新主密码不一致' : null;
                },
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
              const SizedBox(height: 16),
              if (_loggedIn) ...[
                TextFormField(
                  controller: _accountPasswordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '账户密码',
                    helperText: '用于同步云端继承密钥',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => (value == null || value.isEmpty)
                      ? '请输入账户密码以同步云端'
                      : null,
                ),
              ] else ...[
                Text(
                  '未登录,云端继承密钥不会更新',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('确认修改'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../crypto/attempt_guard.dart';
import '../crypto/key_derivation.dart';
import '../crypto/master_password.dart';
import '../logger.dart';
import '../storage/secure_store.dart';
import '../sync/backup.dart';
import '../sync/local_vault.dart';
import '../sync/sync_provider.dart';

/// 同步设置页:配置 WebDAV/S3 备份目标并执行同步/恢复。
/// 配置仅保存在本机安全存储,绝不发送到托孤服务端。
class SyncSettingsPage extends StatefulWidget {
  const SyncSettingsPage({super.key});

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  final _store = SecureStore();
  late final Future<ApiClient> _api = ApiConfig.client();

  String _protocol = 'webdav';
  bool _busy = false;

  final _wdUrl = TextEditingController();
  final _wdUser = TextEditingController();
  final _wdPass = TextEditingController();
  final _wdBasePath = TextEditingController(text: '/bequest');

  final _s3Endpoint = TextEditingController();
  final _s3Bucket = TextEditingController();
  final _s3Region = TextEditingController(text: 'us-east-1');
  final _s3AccessKey = TextEditingController();
  final _s3SecretKey = TextEditingController();
  final _s3Prefix = TextEditingController(text: 'bequest/');

  final _restoreName = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    for (final c in [
      _wdUrl, _wdUser, _wdPass, _wdBasePath,
      _s3Endpoint, _s3Bucket, _s3Region, _s3AccessKey, _s3SecretKey, _s3Prefix,
      _restoreName,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final raw = await _store.readSyncConfig();
    if (raw == null || raw.isEmpty) return;
    try {
      final cfg = jsonDecode(raw);
      if (cfg is! Map<String, dynamic>) return;
      _protocol = cfg['type']?.toString() == 's3' ? 's3' : 'webdav';
      _wdUrl.text = cfg['url']?.toString() ?? '';
      _wdUser.text = cfg['user']?.toString() ?? '';
      _wdPass.text = cfg['password']?.toString() ?? '';
      _wdBasePath.text = cfg['base_path']?.toString() ?? '/bequest';
      _s3Endpoint.text = cfg['endpoint']?.toString() ?? '';
      _s3Bucket.text = cfg['bucket']?.toString() ?? '';
      _s3Region.text = cfg['region']?.toString() ?? 'us-east-1';
      _s3AccessKey.text = cfg['access_key']?.toString() ?? '';
      _s3SecretKey.text = cfg['secret_key']?.toString() ?? '';
      _s3Prefix.text = cfg['prefix']?.toString() ?? 'bequest/';
      _restoreName.text = cfg['restore_name']?.toString() ?? '';
      if (mounted) setState(() {});
    } catch (e) {
      // 配置损坏:忽略,从空白开始。
      Logger.instance.e('sync loadConfig corrupt: $e');
    }
  }

  Map<String, dynamic> _formConfig({String? restoreName}) {
    if (_protocol == 's3') {
      return {
        'type': 's3',
        'endpoint': _s3Endpoint.text.trim(),
        'bucket': _s3Bucket.text.trim(),
        'region': _s3Region.text.trim(),
        'access_key': _s3AccessKey.text.trim(),
        'secret_key': _s3SecretKey.text.trim(),
        'prefix': _s3Prefix.text.trim(),
        'restore_name': ?restoreName,
      };
    }
    return {
      'type': 'webdav',
      'url': _wdUrl.text.trim(),
      'user': _wdUser.text.trim(),
      'password': _wdPass.text,
      'base_path': _wdBasePath.text.trim(),
      'restore_name': ?restoreName,
    };
  }

  Future<void> _save() async {
    await _store.saveSyncConfig(
      jsonEncode(_formConfig(restoreName: _restoreName.text.trim())),
    );
    _snack('配置已保存');
  }

  Future<void> _testConnection() async {
    final provider = syncProviderFromConfig(_formConfig());
    if (provider == null) {
      _snack('请先填写完整的连接信息');
      return;
    }
    setState(() => _busy = true);
    try {
      final ok = await provider.testConnection();
      _snack(ok ? '连接成功' : '连接失败');
    } catch (e) {
      Logger.instance.e('sync testConnection failed: $e');
      _snack('连接失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    final provider = syncProviderFromConfig(_formConfig());
    if (provider == null) {
      _snack('请先填写完整的连接信息');
      return;
    }
    final masterKey = await _store.readMasterKey();
    if (masterKey == null) {
      _snack('请先注册并设置主密码');
      return;
    }
    final jwt = await _store.readJwt();
    setState(() => _busy = true);
    try {
      final backupJson = await buildBackupJson(jwt, await _api, masterKey);
      // 盐随负载上传,供跨设备用主密码恢复。
      final salt =
          await LocalVault().readSalt(masterKey) ?? await _store.readMasterSalt();
      final payload = await buildSyncPayload(backupJson, masterKey, salt: salt);
      final name = 'bequest_backup_${_timestamp()}.json';
      await provider.upload(name, jsonEncode(payload));
      await _store.saveSyncConfig(
        jsonEncode(_formConfig(restoreName: name)),
      );
      _restoreName.text = name;
      _snack('同步完成');
    } on StateError catch (e) {
      Logger.instance.e('sync failed: ${e.message}');
      _snack(e.message);
    } catch (e) {
      Logger.instance.e('sync failed: $e');
      _snack('同步失败,请检查网络与连接配置');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final provider = syncProviderFromConfig(_formConfig());
    if (provider == null) {
      _snack('请先填写完整的连接信息');
      return;
    }
    final name = _restoreName.text.trim();
    if (name.isEmpty) {
      _snack('请先执行一次同步,或填写备份文件名');
      return;
    }
    final jwt = await _store.readJwt();
    setState(() => _busy = true);
    try {
      final payloadJson = await provider.download(name);
      // 优先用本机主密钥;未登录或解密失败时改用主密码 + 负载盐。
      var backupJson = await extractBackupJsonAny(payloadJson);
      String? usedPassword;
      // 失败限流:连续 5 次错误 → 锁定 60 秒,防暴力尝试。
      final guard = AttemptGuard(store: _store, prefix: 'master');
      if (jwt == null || backupJson == null) {
        if (await guard.checkLocked()) {
          _snack('尝试次数过多,请等待 ${await guard.remainingSeconds()} 秒后重试');
          return;
        }
        if (!mounted) return;
        final password = await showMasterPasswordDialog(context);
        if (password == null) return;
        backupJson = await extractBackupJsonAny(payloadJson, password: password);
        usedPassword = password;
      }
      if (backupJson == null) {
        await guard.recordFailure();
        final locked = await guard.checkLocked();
        _snack(
          locked
              ? '尝试次数过多,请等待 ${await guard.remainingSeconds()} 秒后重试'
              : '解密失败(主密码错误或数据被篡改)',
        );
        return;
      }
      if (usedPassword != null) {
        await guard.recordSuccess();
      }
      if (usedPassword != null) {
        // 本机尚无主密钥时,用负载盐派生并保存,本地模式即可解锁。
        final mk = await _store.readMasterKey();
        if (mk == null || mk.isEmpty) {
          final salt = payloadSalt(payloadJson);
          if (salt != null) {
            await _store.saveMasterSalt(salt);
            await _store.saveMasterKey(await deriveMasterKey(usedPassword, salt));
          }
        }
      }
      if (jwt != null) {
        final result = await restoreAssets(backupJson, jwt, await _api);
        _snack('恢复完成: 成功 ${result.ok} 失败 ${result.fail}');
      } else {
        final masterKey = await _store.readMasterKey();
        if (masterKey == null) {
          _snack('未找到主密钥,无法写入本机');
          return;
        }
        await restoreToLocal(backupJson, masterKey);
        _snack('已恢复,可在本地模式使用');
      }
    } catch (e) {
      Logger.instance.e('restore failed: $e');
      _snack('恢复失败,请检查网络与备份文件');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _timestamp() {
    final now = DateTime.now();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${now.year}${pad(now.month)}${pad(now.day)}'
        '_${pad(now.hour)}${pad(now.minute)}${pad(now.second)}';
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('同步设置')),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  '无需登录:备份与恢复均在本地完成,数据只存在您的存储中;'
                  '同步配置仅保存在本机,不会发送到托孤服务端,备份使用主密钥加密。',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('WebDAV'),
                      selected: _protocol == 'webdav',
                      onSelected: (_) => setState(() => _protocol = 'webdav'),
                    ),
                    ChoiceChip(
                      label: const Text('S3'),
                      selected: _protocol == 's3',
                      onSelected: (_) => setState(() => _protocol = 's3'),
                    ),
                    const ChoiceChip(label: Text('FTP(即将支持)'), selected: false, onSelected: null),
                    const ChoiceChip(label: Text('SFTP(即将支持)'), selected: false, onSelected: null),
                  ],
                ),
                const SizedBox(height: 16),
                if (_protocol == 'webdav') ...[
                  _field(_wdUrl, '服务器地址', hint: 'https://dav.example.com/'),
                  _field(_wdUser, '用户名'),
                  _field(_wdPass, '密码', obscure: true),
                  _field(_wdBasePath, '基础路径', hint: '/bequest'),
                ] else ...[
                  _field(_s3Endpoint, '端点', hint: 'https://s3.amazonaws.com'),
                  _field(_s3Bucket, 'Bucket'),
                  _field(_s3Region, 'Region'),
                  _field(_s3AccessKey, 'Access Key'),
                  _field(_s3SecretKey, 'Secret Key', obscure: true),
                  _field(_s3Prefix, '前缀', hint: 'bequest/'),
                ],
                const SizedBox(height: 8),
                _field(_restoreName, '备份文件名(恢复用)', hint: 'bequest_backup_20260101_120000.json'),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _testConnection,
                        child: const Text('测试连接'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: _syncNow,
                        child: const Text('立即同步'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _restore,
                        child: const Text('从备份恢复'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _save,
                        child: const Text('保存配置'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool obscure = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

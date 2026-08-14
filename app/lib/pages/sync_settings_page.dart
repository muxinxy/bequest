import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../crypto/attempt_guard.dart';
import '../crypto/key_derivation.dart';
import '../crypto/master_password.dart';
import '../logger.dart';
import '../storage/secure_store.dart';
import '../sync/auto_backup.dart';
import '../sync/backup.dart';
import '../sync/backup_naming.dart';
import '../sync/local_vault.dart';
import '../sync/sync_provider.dart';

/// 同步设置页:配置 WebDAV/S3 备份目标并执行同步/恢复,支持自动备份。
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

  /// 自动备份配置。
  String _autoBackupInterval = 'off';
  int _autoBackupMax = 3;

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

  /// 最近一次同步的文件名(展示用,不再手动输入)。
  String _lastBackupName = '';

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
      _lastBackupName = cfg['restore_name']?.toString() ?? '';
      _autoBackupInterval = AutoBackupScheduler.intervalKeyOf(cfg);
      _autoBackupMax = AutoBackupScheduler.maxCountOf(cfg);
      if (mounted) setState(() {});
    } catch (e) {
      // 配置损坏:忽略,从空白开始。
      Logger.instance.e('sync loadConfig corrupt: $e');
    }
  }

  Map<String, dynamic> _formConfig({String? restoreName}) {
    final base = <String, dynamic>{
      'auto_backup_interval': _autoBackupInterval,
      'auto_backup_max': '$_autoBackupMax',
      if (restoreName != null && restoreName.isNotEmpty)
        'restore_name': restoreName,
    };
    if (_protocol == 's3') {
      return {
        ...base,
        'type': 's3',
        'endpoint': _s3Endpoint.text.trim(),
        'bucket': _s3Bucket.text.trim(),
        'region': _s3Region.text.trim(),
        'access_key': _s3AccessKey.text.trim(),
        'secret_key': _s3SecretKey.text.trim(),
        'prefix': _s3Prefix.text.trim(),
      };
    }
    return {
      ...base,
      'type': 'webdav',
      'url': _wdUrl.text.trim(),
      'user': _wdUser.text.trim(),
      'password': _wdPass.text,
      'base_path': _wdBasePath.text.trim(),
    };
  }

  Future<void> _save() async {
    await _store.saveSyncConfig(jsonEncode(_formConfig()));
    // 重启自动备份调度(间隔/最大数量变更即时生效)。
    await AutoBackupScheduler.instance.onConfigChanged();
    if (!mounted) return;
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
    } on SyncException catch (e) {
      // 显示具体原因(认证/目录/路径),便于用户定位配置问题。
      Logger.instance.e('sync testConnection failed: ${e.message}');
      _snack(e.message);
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
      // 文件名自动生成:bequest_<用户名>_<设备名>_<时间戳>.json(不手动输入)。
      final username = await _currentUsername(jwt);
      final name = buildBackupFileName(
        username: username,
        deviceName: deviceName(),
        timestamp: _timestamp(),
      );
      await provider.upload(name, jsonEncode(payload));
      // 保存用户名/设备名到配置,供自动备份生成一致文件名。
      await _store.saveSyncConfig(
        jsonEncode({
          ..._formConfig(restoreName: name),
          'username': username,
          'device_name': deviceName(),
        }),
      );
      // 同步完成后轮转(超过最大数量删最旧)。
      await _rotateBackups(provider);
      _lastBackupName = name;
      if (mounted) setState(() {});
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

  /// 当前用户名:云端从 /me 获取,本地/未登录回退 'local'。
  Future<String> _currentUsername(String? jwt) async {
    if (jwt == null || jwt.isEmpty) return 'local';
    try {
      final me = await (await _api).me(jwt);
      final user = (me['user'] as Map<String, dynamic>?)?['username'];
      if (user != null && user.toString().isNotEmpty) return user.toString();
    } catch (_) {
      // 网络失败回退 local。
    }
    return 'local';
  }

  /// 备份轮转:列出备份,超过配置的最大数量删最旧。
  Future<void> _rotateBackups(SyncProvider provider) async {
    final cfg = jsonDecode(await _store.readSyncConfig() ?? '{}');
    final maxCount = AutoBackupScheduler.maxCountOf(
      cfg is Map<String, dynamic> ? cfg : {},
    );
    if (maxCount <= 0) return;
    try {
      final files = await provider.listFiles();
      if (files.length <= maxCount) return;
      for (final f in files.skip(maxCount)) {
        try {
          await provider.delete(f.name);
        } catch (_) {
          // 单条删除失败不阻断。
        }
      }
    } catch (_) {
      // 列不出列表时跳过轮转(服务器可能不支持 PROPFIND)。
    }
  }

  /// 从备份恢复:先弹窗列出远端备份文件,选择后执行恢复。
  /// 删除文件后重新拉取列表;列表不可用(服务器不支持 PROPFIND/List)
  /// 或用户选择「手动输入」时,回退手动填写文件名。
  Future<void> _restore() async {
    final provider = syncProviderFromConfig(_formConfig());
    if (provider == null) {
      _snack('请先填写完整的连接信息');
      return;
    }
    while (mounted) {
      setState(() => _busy = true);
      List<BackupFileInfo> files;
      try {
        files = await provider.listFiles();
      } catch (e) {
        // 服务器不支持文件列表:回退手动输入,而非报错退出。
        if (!mounted) return;
        setState(() => _busy = false);
        Logger.instance.e('list backups failed, fallback to manual: $e');
        final name = await showManualRestoreDialog(context, hint: _lastBackupName);
        if (name == null || !mounted) return;
        await _doRestore(provider, name);
        return;
      }
      if (!mounted) return;
      setState(() => _busy = false);
      if (files.isEmpty) {
        _snack('没有找到备份文件');
        return;
      }
      final result = await showBackupListDialog(
        context,
        files: files,
        onDelete: (f) async {
          try {
            await provider.delete(f.name);
            if (!mounted) return true;
            _snack('已删除 ${f.name}');
            return true;
          } catch (_) {
            if (!mounted) return false;
            _snack('删除失败');
            return false;
          }
        },
      );
      if (result == null || !mounted) return; // 取消
      if (result == _kDeletedSentinel) continue; // 删除后重开列表
      if (result == _kManualSentinel) {
        // 手动输入文件名恢复。
        final name = await showManualRestoreDialog(
          context,
          hint: _lastBackupName,
        );
        if (name == null || !mounted) return;
        await _doRestore(provider, name);
        return;
      }
      await _doRestore(provider, result);
      return;
    }
  }

  Future<void> _doRestore(SyncProvider provider, String name) async {
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
      // 显示具体错误(如 HTTP 302/网络异常),便于定位。
      final msg = e is SyncException
          ? e.message
          : '恢复失败: $e';
      _snack(msg);
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
                if (_lastBackupName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '最近备份: $_lastBackupName',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ),
                const SizedBox(height: 8),
                const Divider(),
                _sectionTitle('自动备份'),
                const Text(
                  '按间隔自动备份到上述存储;备份文件名自动生成(bequest_用户名_设备名_时间戳)。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _autoBackupInterval,
                  decoration: const InputDecoration(
                    labelText: '备份间隔',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: kAutoBackupIntervals.keys
                      .map((k) => DropdownMenuItem(
                            value: k,
                            child: Text(kAutoBackupIntervalLabels[k] ?? k),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() {
                    if (v != null) _autoBackupInterval = v;
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: _autoBackupMax,
                  decoration: const InputDecoration(
                    labelText: '最大备份数量',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: kAutoBackupMaxCounts
                      .map((n) => DropdownMenuItem(
                            value: n,
                            child: Text('$n 份(超出自动删除最旧)'),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() {
                    if (v != null) _autoBackupMax = v;
                  }),
                ),
                const SizedBox(height: 8),
                const Divider(),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy ? null : _testConnection,
                        child: const Text('测试连接'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: _busy ? null : _syncNow,
                        child: const Text('立即备份'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : _restore,
                        child: const Text('从备份恢复'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : _save,
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

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

/// 删除成功标记:弹窗 pop 此值表示"已删除,重新打开列表"。
const _kDeletedSentinel = '__deleted__';

/// 手动输入标记:弹窗 pop 此值表示"用户选择手动填写文件名"。
const _kManualSentinel = '__manual__';

/// 手动输入备份文件名对话框:列表不可用或用户选择时使用。
/// 返回文件名;取消返回 null。
Future<String?> showManualRestoreDialog(
  BuildContext context, {
  String? hint,
}) {
  final controller = TextEditingController(text: hint ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('输入备份文件名'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '备份文件名',
          hintText: '如 bequest_alice_device_20260812_100000.json',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = controller.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop(name);
          },
          child: const Text('恢复'),
        ),
      ],
    ),
  );
}

/// 备份文件列表弹窗:显示文件名/修改时间/大小,支持恢复与删除。
/// 返回选中的文件名(恢复);删除成功返回 [_kDeletedSentinel];
/// 选择手动输入返回 [_kManualSentinel];取消返回 null。
Future<String?> showBackupListDialog(
  BuildContext context, {
  required List<BackupFileInfo> files,
  required Future<bool> Function(BackupFileInfo f) onDelete,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('备份文件(${files.length})'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: files.length + 1, // 末尾追加"手动输入"入口
          itemBuilder: (context, index) {
            if (index == files.length) {
              return ListTile(
                dense: true,
                leading: const Icon(Icons.edit_outlined),
                title: const Text(
                  '手动输入文件名',
                  style: TextStyle(fontSize: 13),
                ),
                onTap: () => Navigator.of(context).pop(_kManualSentinel),
              );
            }
            final f = files[index];
            final modified = f.modified?.toLocal();
            final timeText = modified == null
                ? '未知时间'
                : '${modified.year}-${modified.month.toString().padLeft(2, '0')}-'
                    '${modified.day.toString().padLeft(2, '0')} '
                    '${modified.hour.toString().padLeft(2, '0')}:'
                    '${modified.minute.toString().padLeft(2, '0')}';
            return ListTile(
              dense: true,
              leading: const Icon(Icons.backup_outlined),
              title: Text(f.name, style: const TextStyle(fontSize: 13)),
              subtitle: Text(
                '$timeText · ${f.sizeText}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '恢复',
                    icon: const Icon(Icons.restore, size: 20),
                    onPressed: () => Navigator.of(context).pop(f.name),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () async {
                      final ok = await onDelete(f);
                      if (ok && context.mounted) {
                        Navigator.of(context).pop(_kDeletedSentinel);
                      }
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

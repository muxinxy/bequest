import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// flutter_secure_storage 的薄封装,统一管理本机安全存储的键名。
/// Web 下由 ensureWebSecureStoragePlatform() 在启动时替换为 localStorage 实现。
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _jwtKey = 'bequest_jwt';
  static const _masterKeyKey = 'bequest_master_key';
  static const _masterSaltKey = 'bequest_master_salt';
  static const _wrappingKeyKey = 'bequest_wrapping_key';
  static const _pinHashKey = 'bequest_pin_hash';
  static const _pinSaltKey = 'bequest_pin_salt';
  static const _lockEnabledKey = 'bequest_lock_enabled';
  static const _lockBiometricKey = 'bequest_lock_biometric';
  static const _lockBiometricTypeKey = 'bequest_lock_biometric_type';
  static const _lockTimingKey = 'bequest_lock_timing';
  static const _lockTimeoutKey = 'bequest_lock_timeout_minutes';
  static const _patternHashKey = 'bequest_lock_pattern';
  static const _patternSaltKey = 'bequest_pattern_salt';
  static const _syncConfigKey = 'bequest_sync_config';
  static const _serverUrlKey = 'bequest_server_url';
  static const _recentUrlsKey = 'bequest_recent_urls';
  static const _storageModeKey = 'bequest_storage_mode';
  static const _masterHintKey = 'bequest_master_hint';

  // ---- 本地账户(多账户本地模式) ----
  static const _localProfilesKey = 'bequest_local_profiles';
  static const _activeProfileKey = 'bequest_active_local_profile';
  // 进入本地账户前暂存的标准槽(退出时恢复,避免云端密钥被本地密钥覆盖)。
  static const _preLocalMkKey = 'bequest_pre_local_mk';
  static const _preLocalSaltKey = 'bequest_pre_local_salt';
  static const _preLocalWkKey = 'bequest_pre_local_wk';
  static const _preLocalHintKey = 'bequest_pre_local_hint';

  static String _profileKey(String kind, String id) => 'bequest_local_${kind}_$id';

  final FlutterSecureStorage _storage;

  /// 通用整数读写:失败限流计数与锁定时间戳(millis epoch)。
  Future<void> writeInt(String key, int value) =>
      _storage.write(key: key, value: '$value');

  Future<int?> readInt(String key) async {
    final v = await _storage.read(key: key);
    return int.tryParse(v ?? '');
  }

  Future<void> deleteKey(String key) => _storage.delete(key: key);

  /// 主密码提示语(可选,帮助回忆)。
  Future<void> saveMasterHint(String hint) =>
      _storage.write(key: _masterHintKey, value: hint);

  Future<String?> readMasterHint() => _storage.read(key: _masterHintKey);

  Future<void> saveJwt(String jwt) => _storage.write(key: _jwtKey, value: jwt);

  Future<void> saveMasterKey(String masterKey) =>
      _storage.write(key: _masterKeyKey, value: masterKey);

  Future<void> saveWrappingKey(String wrappingKey) =>
      _storage.write(key: _wrappingKeyKey, value: wrappingKey);

  Future<String?> readJwt() => _storage.read(key: _jwtKey);

  Future<String?> readMasterKey() => _storage.read(key: _masterKeyKey);

  Future<void> saveMasterSalt(String salt) =>
      _storage.write(key: _masterSaltKey, value: salt);

  Future<String?> readMasterSalt() => _storage.read(key: _masterSaltKey);

  Future<String?> readWrappingKey() => _storage.read(key: _wrappingKeyKey);

  Future<void> savePinHash(String hash) =>
      _storage.write(key: _pinHashKey, value: hash);

  Future<String?> readPinHash() => _storage.read(key: _pinHashKey);

  Future<void> savePinSalt(String salt) =>
      _storage.write(key: _pinSaltKey, value: salt);

  Future<String?> readPinSalt() => _storage.read(key: _pinSaltKey);

  Future<void> setLockEnabled(bool value) =>
      _storage.write(key: _lockEnabledKey, value: value ? 'true' : 'false');

  Future<bool> readLockEnabled() async =>
      await _storage.read(key: _lockEnabledKey) == 'true';

  /// 生物识别解锁方式:''(关闭) | 'fingerprint'(指纹) | 'face'(人脸),三选一。
  /// 旧布尔键 [readLockBiometric] 仅作迁移用:新键缺失且旧值为 true 时回落为 'fingerprint'。
  Future<void> setLockBiometricType(String type) async {
    final t = (type == 'fingerprint' || type == 'face') ? type : '';
    await _storage.write(key: _lockBiometricTypeKey, value: t);
    await _storage.delete(key: _lockBiometricKey);
  }

  Future<String> readLockBiometricType() async {
    final v = await _storage.read(key: _lockBiometricTypeKey);
    if (v == 'fingerprint') return 'fingerprint';
    if (v == 'face') return 'face';
    // 新键缺失 → 读旧布尔迁移(首次读取时顺手写回新键)。
    if (await _storage.read(key: _lockBiometricKey) == 'true') {
      await _storage.write(key: _lockBiometricTypeKey, value: 'fingerprint');
      await _storage.delete(key: _lockBiometricKey);
      return 'fingerprint';
    }
    return '';
  }

  // 兼容旧调用方:布尔 ↔ 类型映射('true' 默认指纹)。
  Future<void> setLockBiometric(bool value) =>
      setLockBiometricType(value ? 'fingerprint' : '');

  Future<bool> readLockBiometric() async =>
      (await readLockBiometricType()).isNotEmpty;

  /// 锁定时机:'exit'(退出时锁定,默认) | 'timeout'(退出且超时锁定)。
  Future<void> setLockTiming(String timing) =>
      _storage.write(key: _lockTimingKey, value: timing);

  Future<String> readLockTiming() async {
    final v = await _storage.read(key: _lockTimingKey);
    return v == 'timeout' ? 'timeout' : 'exit';
  }

  /// 超时锁定分钟数(1-60,默认 5)。
  Future<void> setLockTimeoutMinutes(int minutes) =>
      _storage.write(key: _lockTimeoutKey, value: '$minutes');

  Future<int> readLockTimeoutMinutes() async {
    final v = await _storage.read(key: _lockTimeoutKey);
    final n = int.tryParse(v ?? '');
    return (n != null && n >= 1 && n <= 60) ? n : 5;
  }

  Future<void> savePatternHash(String hash) =>
      _storage.write(key: _patternHashKey, value: hash);

  Future<String?> readPatternHash() => _storage.read(key: _patternHashKey);

  Future<void> savePatternSalt(String salt) =>
      _storage.write(key: _patternSaltKey, value: salt);

  Future<String?> readPatternSalt() => _storage.read(key: _patternSaltKey);

  Future<void> clearPattern() async {
    await _storage.delete(key: _patternHashKey);
    await _storage.delete(key: _patternSaltKey);
  }

  /// 清除应用锁全部凭据与开关(退出登录/退出本地模式时调用,
  /// 回到登录页不再被锁屏拦截;与 clearAll 行为一致)。
  Future<void> clearAppLock() async {
    await _storage.delete(key: _pinHashKey);
    await _storage.delete(key: _pinSaltKey);
    await _storage.delete(key: _patternHashKey);
    await _storage.delete(key: _patternSaltKey);
    await _storage.delete(key: _lockEnabledKey);
    await _storage.delete(key: _lockBiometricKey);
    await _storage.delete(key: _lockBiometricTypeKey);
  }

  /// 清除会话数据(退出登录/换号)。以下为设备级配置与加密状态,默认保留:
  /// - 服务器地址/最近地址:每次登录都要重填太烦;
  /// - 主密钥/盐/包装密钥/提示语:退出登录不该当作"换新设备",
  ///   否则同一设备每次登录都要重新恢复加密密钥。
  /// 会话凭据(JWT)与 PIN/图案锁全部清除。
  ///
  /// [keepKeys] 为 false 时连加密凭据一并清除(公共电脑/彻底退出场景,
  /// 由退出登录确认对话框让用户选择)。
  Future<void> clearAll({bool keepKeys = true}) async {
    final serverUrl = await readServerUrl();
    final recentUrls = await readRecentUrls();
    final masterKey = keepKeys ? await readMasterKey() : null;
    final masterSalt = keepKeys ? await readMasterSalt() : null;
    final wrappingKey = keepKeys ? await readWrappingKey() : null;
    final masterHint = keepKeys ? await readMasterHint() : null;
    await _storage.deleteAll();
    if (serverUrl != null && serverUrl.isNotEmpty) {
      await saveServerUrl(serverUrl);
    }
    if (recentUrls.isNotEmpty) {
      await saveRecentUrls(recentUrls);
    }
    if (masterKey != null && masterKey.isNotEmpty) {
      await saveMasterKey(masterKey);
    }
    if (masterSalt != null && masterSalt.isNotEmpty) {
      await saveMasterSalt(masterSalt);
    }
    if (wrappingKey != null && wrappingKey.isNotEmpty) {
      await saveWrappingKey(wrappingKey);
    }
    if (masterHint != null && masterHint.isNotEmpty) {
      await saveMasterHint(masterHint);
    }
  }

  // 同步配置仅保存在本机(隐私优先),绝不发送给托孤服务端。
  /// 同步配置:云端模式用全局键;本地模式下按账户隔离
  /// (各本地账户独立 WebDAV/S3 目标,互不覆盖)。
  Future<String> _syncConfigKeyFor() async {
    final active = await readActiveLocalProfileId();
    if (active != null && active.isNotEmpty) {
      return '${_syncConfigKey}_$active';
    }
    return _syncConfigKey;
  }

  Future<void> saveSyncConfig(String json) async =>
      _storage.write(key: await _syncConfigKeyFor(), value: json);

  Future<String?> readSyncConfig() async =>
      _storage.read(key: await _syncConfigKeyFor());

  /// 服务器地址覆盖(设置页写入;为空则用 ApiConfig.defaultBaseUrl)。
  Future<String?> readServerUrl() => _storage.read(key: _serverUrlKey);

  Future<void> saveServerUrl(String url) =>
      _storage.write(key: _serverUrlKey, value: url);

  /// 最近使用的服务器地址列表(JSON 数组,新→旧)。快速填入 + 可清除。
  Future<List<String>> readRecentUrls() async {
    final raw = await _storage.read(key: _recentUrlsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } catch (_) {
      // 数据损坏:忽略。
    }
    return const [];
  }

  Future<void> saveRecentUrls(List<String> urls) =>
      _storage.write(key: _recentUrlsKey, value: jsonEncode(urls));

  /// 存储模式:'cloud' | 'local' | null(默认 cloud)。
  Future<String?> readStorageMode() => _storage.read(key: _storageModeKey);

  Future<void> saveStorageMode(String mode) =>
      _storage.write(key: _storageModeKey, value: mode);

  // ---------- 本地账户(多账户本地模式) ----------

  /// 本地账户列表:[{id, name}],空 = 尚未建立任何本地账户。
  Future<List<Map<String, String>>> readLocalProfiles() async {
    final raw = await _storage.read(key: _localProfilesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map((m) => m.map((k, v) => MapEntry(k, v.toString())))
            .toList(growable: false);
      }
    } catch (_) {
      // 数据损坏:按无账户处理。
    }
    return const [];
  }

  Future<String?> readActiveLocalProfileId() =>
      _storage.read(key: _activeProfileKey);

  /// 进入本地账户前暂存当前标准槽(只存一次,嵌套进入不覆盖)。
  /// 含主密码提示语:账户 hint 切换时标准槽要跟着走,退出需恢复。
  Future<void> _stashStandardSlots() async {
    // 任一 pre 键已存 = 已进入本地模式,不再覆盖暂存值。
    final alreadyStashed = (await _storage.read(key: _preLocalMkKey)) != null ||
        (await _storage.read(key: _preLocalHintKey)) != null;
    if (alreadyStashed) return;
    final mk = await _storage.read(key: _masterKeyKey);
    final salt = await _storage.read(key: _masterSaltKey);
    final wk = await _storage.read(key: _wrappingKeyKey);
    final hint = await _storage.read(key: _masterHintKey);
    if (mk != null) await _storage.write(key: _preLocalMkKey, value: mk);
    if (salt != null) await _storage.write(key: _preLocalSaltKey, value: salt);
    if (wk != null) await _storage.write(key: _preLocalWkKey, value: wk);
    if (hint != null) await _storage.write(key: _preLocalHintKey, value: hint);
  }

  /// 退出本地模式:恢复暂存的标准槽并清除。
  Future<void> _restoreStashedSlots() async {
    for (final (key, slot) in [
      (_preLocalMkKey, _masterKeyKey),
      (_preLocalSaltKey, _masterSaltKey),
      (_preLocalWkKey, _wrappingKeyKey),
      (_preLocalHintKey, _masterHintKey),
    ]) {
      final v = await _storage.read(key: key);
      if (v != null) {
        await _storage.write(key: slot, value: v);
      } else {
        await _storage.delete(key: slot);
      }
      await _storage.delete(key: key);
    }
  }

  Future<void> _writeStandardSlots(String mk, String salt, String wk) async {
    await _storage.write(key: _masterKeyKey, value: mk);
    await _storage.write(key: _masterSaltKey, value: salt);
    await _storage.write(key: _wrappingKeyKey, value: wk);
  }

  /// 新建本地账户:账户密钥入专属槽位,并写入标准槽(现有本地代码无感)、设为当前账户。
  Future<void> createLocalProfile({
    required String id,
    required String name,
    required String masterKey,
    required String salt,
    required String wrappingKey,
    String hint = '',
  }) async {
    await _stashStandardSlots();
    await _storage.write(key: _profileKey('mk', id), value: masterKey);
    await _storage.write(key: _profileKey('salt', id), value: salt);
    await _storage.write(key: _profileKey('wk', id), value: wrappingKey);
    if (hint.isNotEmpty) {
      await _storage.write(key: _profileKey('hint', id), value: hint);
    }
    await _writeStandardSlots(masterKey, salt, wrappingKey);
    // 提示语同步标准槽:锁屏/验证弹窗读标准槽,不写则本地模式不显示提示语。
    if (hint.isNotEmpty) {
      await _storage.write(key: _masterHintKey, value: hint);
    } else {
      await _storage.delete(key: _masterHintKey);
    }
    final profiles = [...await readLocalProfiles()];
    profiles.add({'id': id, 'name': name});
    await _storage.write(key: _localProfilesKey, value: jsonEncode(profiles));
    await _storage.write(key: _activeProfileKey, value: id);
  }

  /// 切换本地账户:该账户密钥写入标准槽并设为当前账户。
  Future<void> activateLocalProfile(String id) async {
    await _stashStandardSlots();
    final mk = await _storage.read(key: _profileKey('mk', id));
    final salt = await _storage.read(key: _profileKey('salt', id));
    final wk = await _storage.read(key: _profileKey('wk', id));
    await _writeStandardSlots(mk ?? '', salt ?? '', wk ?? '');
    // 账户提示语同步标准槽;账户无提示语则清空(切换后不显示上一个账户的)。
    final hint = await _storage.read(key: _profileKey('hint', id));
    if (hint != null && hint.isNotEmpty) {
      await _storage.write(key: _masterHintKey, value: hint);
    } else {
      await _storage.delete(key: _masterHintKey);
    }
    await _storage.write(key: _activeProfileKey, value: id);
  }

  /// 退出本地模式:恢复进入前暂存的标准槽(云端密钥),清空当前账户标记。
  Future<void> deactivateLocalProfile() async {
    await _restoreStashedSlots();
    await _storage.delete(key: _activeProfileKey);
  }

  /// 读取账户密钥(进入验证用)。
  Future<({String? mk, String? salt, String? wk, String? hint})>
      readLocalProfile(String id) async {
    final mk = await _storage.read(key: _profileKey('mk', id));
    final salt = await _storage.read(key: _profileKey('salt', id));
    final wk = await _storage.read(key: _profileKey('wk', id));
    final hint = await _storage.read(key: _profileKey('hint', id));
    return (mk: mk, salt: salt, wk: wk, hint: hint);
  }

  /// 删除本地账户:清账户密钥与列表项;若为当前账户先退出。
  /// vault 文件残留无害(读不到即空库)。
  Future<void> deleteLocalProfile(String id) async {
    if (await readActiveLocalProfileId() == id) {
      await deactivateLocalProfile();
    }
    for (final kind in const ['mk', 'salt', 'wk', 'hint']) {
      await _storage.delete(key: _profileKey(kind, id));
    }
    final profiles = [...await readLocalProfiles()];
    profiles.removeWhere((p) => p['id'] == id);
    await _storage.write(key: _localProfilesKey, value: jsonEncode(profiles));
  }

  /// 旧版单账户迁移:标准槽已有本地主密钥但无账户列表 →
  /// 登记为 'legacy' 账户(沿用原 vault.bq,零数据迁移)。
  Future<bool> migrateLegacyLocalProfile() async {
    final profiles = await readLocalProfiles();
    if (profiles.isNotEmpty) return false;
    final mk = await _storage.read(key: _masterKeyKey);
    final salt = await _storage.read(key: _masterSaltKey);
    if (mk == null || mk.isEmpty || salt == null || salt.isEmpty) return false;
    final wk = await _storage.read(key: _wrappingKeyKey) ?? '';
    await _storage.write(key: _profileKey('mk', 'legacy'), value: mk);
    await _storage.write(key: _profileKey('salt', 'legacy'), value: salt);
    await _storage.write(key: _profileKey('wk', 'legacy'), value: wk);
    final hint = await _storage.read(key: _masterHintKey);
    if (hint != null) {
      await _storage.write(key: _profileKey('hint', 'legacy'), value: hint);
    }
    await _storage.write(
      key: _localProfilesKey,
      value: jsonEncode([
        {'id': 'legacy', 'name': '本地账户'}
      ]),
    );
    await _storage.write(key: _activeProfileKey, value: 'legacy');
    return true;
  }
}

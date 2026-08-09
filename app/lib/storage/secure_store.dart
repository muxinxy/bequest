import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// flutter_secure_storage 的薄封装,统一管理本机安全存储的键名。
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
  static const _syncConfigKey = 'bequest_sync_config';
  static const _serverUrlKey = 'bequest_server_url';
  static const _storageModeKey = 'bequest_storage_mode';

  final FlutterSecureStorage _storage;

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

  Future<void> setLockBiometric(bool value) =>
      _storage.write(key: _lockBiometricKey, value: value ? 'true' : 'false');

  Future<bool> readLockBiometric() async =>
      await _storage.read(key: _lockBiometricKey) == 'true';

  Future<void> clearAll() => _storage.deleteAll();

  // 同步配置仅保存在本机(隐私优先),绝不发送给托孤服务端。
  Future<void> saveSyncConfig(String json) =>
      _storage.write(key: _syncConfigKey, value: json);

  Future<String?> readSyncConfig() => _storage.read(key: _syncConfigKey);

  /// 服务器地址覆盖(设置页写入;为空则用 ApiConfig.defaultBaseUrl)。
  Future<String?> readServerUrl() => _storage.read(key: _serverUrlKey);

  Future<void> saveServerUrl(String url) =>
      _storage.write(key: _serverUrlKey, value: url);

  /// 存储模式:'cloud' | 'local' | null(默认 cloud)。
  Future<String?> readStorageMode() => _storage.read(key: _storageModeKey);

  Future<void> saveStorageMode(String mode) =>
      _storage.write(key: _storageModeKey, value: mode);
}

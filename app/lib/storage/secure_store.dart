import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// flutter_secure_storage 的薄封装,统一管理本机安全存储的键名。
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _jwtKey = 'bequest_jwt';
  static const _masterKeyKey = 'bequest_master_key';
  static const _wrappingKeyKey = 'bequest_wrapping_key';
  static const _pinHashKey = 'bequest_pin_hash';
  static const _pinSaltKey = 'bequest_pin_salt';
  static const _lockEnabledKey = 'bequest_lock_enabled';
  static const _lockBiometricKey = 'bequest_lock_biometric';

  final FlutterSecureStorage _storage;

  Future<void> saveJwt(String jwt) => _storage.write(key: _jwtKey, value: jwt);

  Future<void> saveMasterKey(String masterKey) =>
      _storage.write(key: _masterKeyKey, value: masterKey);

  Future<void> saveWrappingKey(String wrappingKey) =>
      _storage.write(key: _wrappingKeyKey, value: wrappingKey);

  Future<String?> readJwt() => _storage.read(key: _jwtKey);

  Future<String?> readMasterKey() => _storage.read(key: _masterKeyKey);

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
}

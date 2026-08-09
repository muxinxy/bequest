import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// flutter_secure_storage 的薄封装,统一管理本机安全存储的键名。
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _jwtKey = 'bequest_jwt';
  static const _masterKeyKey = 'bequest_master_key';
  static const _wrappingKeyKey = 'bequest_wrapping_key';

  final FlutterSecureStorage _storage;

  Future<void> saveJwt(String jwt) => _storage.write(key: _jwtKey, value: jwt);

  Future<void> saveMasterKey(String masterKey) =>
      _storage.write(key: _masterKeyKey, value: masterKey);

  Future<void> saveWrappingKey(String wrappingKey) =>
      _storage.write(key: _wrappingKeyKey, value: wrappingKey);

  Future<String?> readJwt() => _storage.read(key: _jwtKey);

  Future<String?> readMasterKey() => _storage.read(key: _masterKeyKey);

  Future<String?> readWrappingKey() => _storage.read(key: _wrappingKeyKey);

  Future<void> clearAll() => _storage.deleteAll();
}

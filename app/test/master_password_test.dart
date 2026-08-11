import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/crypto/key_derivation.dart';
import 'package:bequest/crypto/master_password.dart';
import 'package:bequest/storage/secure_store.dart';

void main() {
  const salt = 'c2FsdA=='; // base64("salt")
  late SecureStore store;

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    store = SecureStore();
  });

  test('盐缺失(旧账号未保存)返回 false', () async {
    await store.saveMasterKey(await deriveMasterKey('password', salt));
    expect(await verifyMasterPassword('password', store: store), isFalse);
  });

  test('正确主密码返回 true', () async {
    await store.saveMasterSalt(salt);
    await store.saveMasterKey(await deriveMasterKey('correct', salt));
    expect(await verifyMasterPassword('correct', store: store), isTrue);
  });

  test('错误主密码返回 false', () async {
    await store.saveMasterSalt(salt);
    await store.saveMasterKey(await deriveMasterKey('correct', salt));
    expect(await verifyMasterPassword('wrong', store: store), isFalse);
  });
}

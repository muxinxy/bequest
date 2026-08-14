import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/storage/secure_store.dart';
import 'package:bequest/sync/backup_naming.dart';

void main() {
  group('buildBackupFileName', () {
    test('用户名+设备名+时间戳拼接,json 后缀', () {
      expect(
        buildBackupFileName(
          username: 'alice',
          deviceName: 'Pixel-8',
          timestamp: '20260812_100000',
        ),
        'bequest_alice_Pixel-8_20260812_100000.json',
      );
    });

    test('特殊字符清洗为下划线,空用户名/设备名跳过对应段', () {
      // 中文/空格/!均不在 [A-Za-z0-9_-] 内 → 各替换为一个下划线。
      expect(
        buildBackupFileName(
          username: '张 三!',
          deviceName: '',
          timestamp: '20260812_100000',
        ),
        'bequest___20260812_100000.json',
      );
      expect(
        buildBackupFileName(
          username: '',
          deviceName: '',
          timestamp: '20260812_100000',
        ),
        'bequest_20260812_100000.json',
      );
    });
  });

  group('currentAccountName', () {
    late SecureStore store;

    setUp(() {
      FlutterSecureStoragePlatform.instance =
          TestFlutterSecureStoragePlatform({});
      store = SecureStore();
    });

    test('本地模式:当前激活账户的名称', () async {
      await store.createLocalProfile(
        id: 'p1',
        name: '张三',
        masterKey: 'mk-1',
        salt: 'salt-1',
        wrappingKey: 'wk-1',
      );
      expect(await currentAccountName(store: store), '张三');
    });

    test('云端用户名优先于本地账户名', () async {
      await store.createLocalProfile(
        id: 'p1',
        name: '张三',
        masterKey: 'mk-1',
        salt: 'salt-1',
        wrappingKey: 'wk-1',
      );
      expect(
        await currentAccountName(cloudUsername: 'alice', store: store),
        'alice',
      );
    });

    test('无账户回退 local', () async {
      expect(await currentAccountName(store: store), 'local');
    });
  });
}

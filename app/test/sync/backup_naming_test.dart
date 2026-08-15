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

    test('特殊字符清洗:中文保留,空白/符号替换,空段跳过', () {
      // 中文不再被清洗(保留 Unicode),空白与符号替换为下划线。
      expect(
        buildBackupFileName(
          username: '张三 三!',
          deviceName: '',
          timestamp: '20260812_100000',
        ),
        'bequest_张三_三_20260812_100000.json',
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

    test('isBackupForAccount: 匹配当前账户前缀,忽略他人备份', () {
      expect(isBackupForAccount('bequest_alice_dev_20260812.json', 'alice'), isTrue);
      expect(isBackupForAccount('bequest_bob_dev_20260812.json', 'alice'), isFalse);
      expect(isBackupForAccount('bequest_张三_web_20260812.json', '张三'), isTrue);
      expect(isBackupForAccount('other_file.json', 'alice'), isFalse);
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

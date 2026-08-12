import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/storage/secure_store.dart';

void main() {
  late SecureStore store;

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    store = SecureStore();
  });

  test('本地账户:创建/激活/退出恢复标准槽/删除', () async {
    // 模拟云端已有密钥在标准槽。
    await store.saveMasterKey('cloud-mk');
    await store.saveMasterSalt('cloud-salt');
    await store.saveWrappingKey('cloud-wk');

    // 创建本地账户:密钥入账户槽,标准槽被本地密钥覆盖。
    await store.createLocalProfile(
      id: 'p1',
      name: '张三',
      masterKey: 'local-mk-1',
      salt: 'local-salt-1',
      wrappingKey: 'local-wk-1',
      hint: '纪念日',
    );
    expect(await store.readMasterKey(), 'local-mk-1');
    expect(await store.readActiveLocalProfileId(), 'p1');
    var profiles = await store.readLocalProfiles();
    expect(profiles.length, 1);
    expect(profiles.first['name'], '张三');

    // 第二个账户:切换后标准槽换为账户 2 的密钥。
    await store.createLocalProfile(
      id: 'p2',
      name: '李四',
      masterKey: 'local-mk-2',
      salt: 'local-salt-2',
      wrappingKey: 'local-wk-2',
    );
    expect(await store.readMasterKey(), 'local-mk-2');
    expect(await store.readActiveLocalProfileId(), 'p2');
    profiles = await store.readLocalProfiles();
    expect(profiles.length, 2);

    // 切回账户 1:密钥正确且 hint 保留。
    await store.activateLocalProfile('p1');
    expect(await store.readMasterKey(), 'local-mk-1');
    final p1 = await store.readLocalProfile('p1');
    expect(p1.hint, '纪念日');

    // 退出本地模式:恢复云端的标准槽,清空当前账户标记。
    await store.deactivateLocalProfile();
    expect(await store.readMasterKey(), 'cloud-mk');
    expect(await store.readMasterSalt(), 'cloud-salt');
    expect(await store.readWrappingKey(), 'cloud-wk');
    expect(await store.readActiveLocalProfileId(), isNull);
    // 账户列表仍在(再次进入可选)。
    profiles = await store.readLocalProfiles();
    expect(profiles.length, 2);

    // 删除账户 2。
    await store.deleteLocalProfile('p2');
    profiles = await store.readLocalProfiles();
    expect(profiles.length, 1);
    expect(profiles.first['id'], 'p1');
    expect((await store.readLocalProfile('p2')).mk, isNull);
  });

  test('旧版单账户迁移:标准槽有主密钥 → 登记为 legacy 账户', () async {
    await store.saveMasterKey('legacy-mk');
    await store.saveMasterSalt('legacy-salt');
    final migrated = await store.migrateLegacyLocalProfile();
    expect(migrated, isTrue);
    expect(await store.readActiveLocalProfileId(), 'legacy');
    final p = await store.readLocalProfile('legacy');
    expect(p.mk, 'legacy-mk');
    expect(p.salt, 'legacy-salt');
    // 再次调用不重复登记。
    expect(await store.migrateLegacyLocalProfile(), isFalse);
  });

  test('退出登录(clearAll):保留加密凭据与服务器地址,清除会话/锁凭据', () async {
    // 模拟已登录设备:加密凭据 + 服务器配置 + 会话 + 应用锁。
    await store.saveJwt('jwt-token');
    await store.saveMasterKey('mk');
    await store.saveMasterSalt('salt');
    await store.saveWrappingKey('wk');
    await store.saveMasterHint('提示');
    await store.saveServerUrl('http://10.0.2.2:8080');
    await store.saveRecentUrls(['http://10.0.2.2:8080']);
    await store.savePinHash('pin-hash');
    await store.savePatternHash('pattern-hash');
    await store.saveStorageMode('cloud');

    await store.clearAll();

    // 加密凭据必须保留:否则同一设备每次登录都要恢复密钥。
    expect(await store.readMasterKey(), 'mk');
    expect(await store.readMasterSalt(), 'salt');
    expect(await store.readWrappingKey(), 'wk');
    expect(await store.readMasterHint(), '提示');
    // 服务器地址是设备级配置,同样保留。
    expect(await store.readServerUrl(), 'http://10.0.2.2:8080');
    expect(await store.readRecentUrls(), ['http://10.0.2.2:8080']);
    // 会话与锁凭据必须清除。
    expect(await store.readJwt(), isNull);
    expect(await store.readPinHash(), isNull);
    expect(await store.readPatternHash(), isNull);
    // 存储模式回落到默认云端。
    expect(await store.readStorageMode(), isNull);
  });

  test('退出登录并清除密钥(keepKeys=false):加密凭据一并删除,服务器地址保留', () async {
    await store.saveMasterKey('mk');
    await store.saveMasterSalt('salt');
    await store.saveWrappingKey('wk');
    await store.saveServerUrl('http://10.0.2.2:8080');

    await store.clearAll(keepKeys: false);

    expect(await store.readMasterKey(), isNull);
    expect(await store.readMasterSalt(), isNull);
    expect(await store.readWrappingKey(), isNull);
    // 服务器地址仍是设备级配置,保留。
    expect(await store.readServerUrl(), 'http://10.0.2.2:8080');
  });
}

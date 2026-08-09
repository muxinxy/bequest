import 'dart:io';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/crypto/key_derivation.dart';
import 'package:bequest/crypto/master_key_change.dart';
import 'package:bequest/storage/secure_store.dart';
import 'package:bequest/sync/local_vault.dart';

void main() {
  const salt = 'c2FsdA=='; // base64("salt")
  const oldPassword = 'old-password';
  const newPassword = 'new-password-123';

  late Directory tempDir;
  late LocalVault vault;
  late SecureStore store;

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    store = SecureStore();
    tempDir = Directory.systemTemp.createTempSync('bequest_mkc_test');
    vault = LocalVault(directory: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('reencryptVault', () {
    test('旧密钥写 → 新密钥重加密 → 新密钥可读,旧密钥不可读', () async {
      final oldMk = deriveMasterKey(oldPassword, salt);
      final newMk = deriveMasterKey(newPassword, 'bmV3c2FsdA==');
      await vault.saveLocalData(
        {'schema': 1, 'assets': <Map<String, dynamic>>[], 'categories': <Map<String, dynamic>>[]},
        oldMk,
        salt: salt,
      );
      final ok = await reencryptVault(
        oldMk: oldMk,
        newMk: newMk,
        newSalt: 'bmV3c2FsdA==',
        vault: vault,
      );
      expect(ok, isTrue);
      final data = await vault.loadLocalData(newMk);
      expect(data, isNotNull);
      expect(data!['schema'], 1);
      // 快照内 salt 同步为新盐(跨设备恢复用)。
      expect(data['salt'], 'bmV3c2FsdA==');
      expect(await vault.loadLocalData(oldMk), isNull);
    });

    test('文件缺失 → false 不抛异常', () async {
      final ok = await reencryptVault(
        oldMk: 'old',
        newMk: 'new',
        newSalt: 'salt',
        vault: vault,
      );
      expect(ok, isFalse);
    });

    test('旧版备份串(无 schema)→ false 且文件不被覆盖', () async {
      final oldMk = deriveMasterKey(oldPassword, salt);
      const backup = '{"app":"bequest","type":"backup","version":1,"assets":[]}';
      await vault.saveVault(backup, oldMk);
      final ok = await reencryptVault(
        oldMk: oldMk,
        newMk: deriveMasterKey(newPassword, 'bmV3c2FsdA=='),
        newSalt: 'bmV3c2FsdA==',
        vault: vault,
      );
      expect(ok, isFalse);
      expect(await vault.loadVault(oldMk), backup, reason: '备份串应原样保留');
    });

    test('密钥错误 → false 不抛异常', () async {
      final oldMk = deriveMasterKey(oldPassword, salt);
      await vault.saveLocalData(
        {'schema': 1, 'assets': <Map<String, dynamic>>[]},
        oldMk,
      );
      final ok = await reencryptVault(
        oldMk: 'wrong-key',
        newMk: 'new',
        newSalt: 'salt',
        vault: vault,
      );
      expect(ok, isFalse);
    });
  });

  group('changeMasterPasswordLocal(本地路径)', () {
    Future<void> seedOld() async {
      final oldMk = deriveMasterKey(oldPassword, salt);
      await store.saveMasterSalt(salt);
      await store.saveMasterKey(oldMk);
      await store.saveMasterHint('旧提示');
      await vault.saveLocalData(
        {
          'schema': 1,
          'assets': <Map<String, dynamic>>[],
          'categories': <Map<String, dynamic>>[],
        },
        oldMk,
        salt: salt,
      );
    }

    test('旧密码校验通过:重加密本地库并更新密钥/盐/提示语', () async {
      await seedOld();
      final oldMk = await store.readMasterKey();
      final result = await changeMasterPasswordLocal(
        store: store,
        vault: vault,
        verifyOld: (pw) async => pw == oldPassword,
        oldPassword: oldPassword,
        newPassword: newPassword,
        newHint: '新提示',
      );
      expect(result.ok, isTrue);
      expect(result.error, isNull);
      expect(result.newMk, isNotNull);
      expect(result.newMk, isNot(oldMk));
      // SecureStore 已更新。
      final newSalt = await store.readMasterSalt();
      expect(newSalt, isNot(salt));
      expect(await store.readMasterKey(), result.newMk);
      expect(await store.readMasterHint(), '新提示');
      // 本地库可用新密钥读取,旧密钥失效。
      final data = await vault.loadLocalData(result.newMk!);
      expect(data, isNotNull);
      expect(data!['salt'], newSalt);
      expect(await vault.loadLocalData(oldMk!), isNull);
    });

    test('旧密码校验失败:中止且本机状态不变', () async {
      await seedOld();
      final oldMk = await store.readMasterKey();
      final result = await changeMasterPasswordLocal(
        store: store,
        vault: vault,
        verifyOld: (pw) async => false,
        oldPassword: 'wrong-old',
        newPassword: newPassword,
        newHint: '不应生效',
      );
      expect(result.ok, isFalse);
      expect(result.error, isNull);
      expect(await store.readMasterKey(), oldMk);
      expect(await store.readMasterHint(), '旧提示');
      expect(await vault.loadLocalData(oldMk!), isNotNull);
    });

    test('旧密码校验通过但本地无主密钥 → 报错中止', () async {
      final result = await changeMasterPasswordLocal(
        store: store,
        vault: vault,
        verifyOld: (pw) async => true,
        oldPassword: oldPassword,
        newPassword: newPassword,
        newHint: '',
      );
      expect(result.ok, isFalse);
      expect(result.error, '未找到当前主密钥,无法修改');
    });
  });
}

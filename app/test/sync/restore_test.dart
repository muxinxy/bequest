import 'dart:convert';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/crypto/key_derivation.dart';
import 'package:bequest/pages/local_unlock_page.dart';
import 'package:bequest/storage/secure_store.dart';
import 'package:bequest/sync/backup.dart';

void main() {
  const salt = 'c2FsdA=='; // base64("salt")
  const password = 'correct-password';
  const backupJson =
      '{"app":"bequest","type":"backup","version":1,"assets":[]}';
  late SecureStore store;

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    store = SecureStore();
  });

  test('localUnlockStep:已有主密钥 → 解锁,否则 → 设置', () {
    expect(localUnlockStep(hasMasterKey: false), LocalUnlockStep.setup);
    expect(localUnlockStep(hasMasterKey: true), LocalUnlockStep.unlock);
  });

  group('extractBackupJsonAny', () {
    final mk = deriveMasterKey(password, salt);

    test('本机已存主密钥 → 直接解密', () async {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({
        'bequest_master_key': mk,
      });
      store = SecureStore();
      final payload = jsonEncode(
        await buildSyncPayload(backupJson, mk, salt: salt),
      );
      expect(await extractBackupJsonAny(payload, store: store), backupJson);
    });

    test('无本机密钥 + 正确主密码(用负载内盐派生)→ 解密', () async {
      final payload = jsonEncode(
        await buildSyncPayload(backupJson, mk, salt: salt),
      );
      expect(
        await extractBackupJsonAny(payload, password: password, store: store),
        backupJson,
      );
    });

    test('错误主密码 → null', () async {
      final payload = jsonEncode(
        await buildSyncPayload(backupJson, mk, salt: salt),
      );
      expect(
        await extractBackupJsonAny(payload, password: 'wrong', store: store),
        isNull,
      );
    });

    test('负载无盐且本机无密钥 → null', () async {
      final payload = jsonEncode(await buildSyncPayload(backupJson, mk));
      expect(
        await extractBackupJsonAny(payload, password: password, store: store),
        isNull,
      );
    });
  });
}

import 'dart:io';

import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/repository/cloud_asset_repository.dart';
import 'package:bequest/repository/local_asset_repository.dart';
import 'package:bequest/repository/repository_factory.dart';
import 'package:bequest/sync/local_vault.dart';

void main() {
  const key = 'a2V5'; // 32 字节密钥的 base64 占位(本地仓储构造不需要真实密钥)。
  late Directory tempDir;

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    tempDir = Directory.systemTemp.createTempSync('bequest_factory_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('默认模式 + jwt → CloudAssetRepository', () async {
    final repo = await RepositoryFactory.resolve(jwt: 'token', masterKeyB64: key);
    expect(repo, isA<CloudAssetRepository>());
  });

  test('本地模式 + 无 jwt → LocalAssetRepository', () async {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({
      'bequest_storage_mode': 'local',
    });
    final repo = await RepositoryFactory.resolve(
      jwt: null,
      masterKeyB64: key,
      vault: LocalVault(directory: tempDir.path),
    );
    expect(repo, isA<LocalAssetRepository>());
  });

  test('本地模式 + 有 jwt 也走本地', () async {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({
      'bequest_storage_mode': 'local',
    });
    final repo = await RepositoryFactory.resolve(
      jwt: 'token',
      masterKeyB64: key,
      vault: LocalVault(directory: tempDir.path),
    );
    expect(repo, isA<LocalAssetRepository>());
  });

  test('无 jwt + 非本地模式 → 本地仓储(未登录默认本地可用)', () async {
    final repo = await RepositoryFactory.resolve(
      jwt: null,
      masterKeyB64: key,
      vault: LocalVault(directory: tempDir.path),
    );
    expect(repo, isA<LocalAssetRepository>());
  });
}

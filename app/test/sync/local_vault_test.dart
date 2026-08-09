import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/sync/local_vault.dart';

/// 本地加密快照:纯文件 + crypto,临时目录注入,无插件依赖。
void main() {
  final key = base64.encode(List<int>.filled(32, 7));
  final wrongKey = base64.encode(List<int>.filled(32, 8));

  late Directory tempDir;
  late LocalVault vault;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('bequest_vault_test');
    vault = LocalVault(directory: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('save→load 往返:正确主密钥取回原文', () async {
    const backup = '{"app":"bequest","type":"backup","version":1,"assets":[]}';
    await vault.saveVault(backup, key);
    expect(await vault.loadVault(key), backup);
  });

  test('错误主密钥 → null(解密/校验失败)', () async {
    await vault.saveVault('{"a":1}', key);
    expect(await vault.loadVault(wrongKey), isNull);
  });

  test('文件缺失 → null', () async {
    expect(await vault.loadVault(key), isNull);
  });

  test('clearVault 后 → null', () async {
    await vault.saveVault('{"a":1}', key);
    await vault.clearVault();
    expect(await vault.loadVault(key), isNull);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/repository/offline_asset_repository.dart';
import 'package:bequest/sync/local_vault.dart';

void main() {
  final key = base64.encode(List<int>.filled(32, 7));

  late Directory tempDir;
  late LocalVault vault;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('bequest_offline_test');
    vault = LocalVault(directory: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('离线仓库:从备份 JSON 读取资产/分类;写操作抛错', () async {
    // 模拟 refreshLocalVault 写入的备份 JSON。
    await vault.saveVault(
      jsonEncode({
        'app': 'bequest',
        'type': 'backup',
        'version': 1,
        'assets': [
          {
            'id': '1',
            'name': '支付宝',
            'asset_type': 'virtual',
            'encrypted_data': 'blob1',
            'expiry_date': '2026-12-31',
          },
        ],
        'categories': [
          {'id': 'c1', 'name': '账户'},
        ],
        'inheritors': [
          {'id': 'i1', 'name': '张三', 'access_code': '1234', 'asset_count': 1},
        ],
        'logs': [
          {'kind': 'audit', 'action': '新增资产「支付宝」', 'created_at': '2026-08-01 10:00:00'},
        ],
      }),
      key,
    );
    final repo = OfflineAssetRepository(masterKeyB64: key, vault: vault);

    expect(await repo.listAssets(), hasLength(1));
    expect(await repo.listCategories(), hasLength(1));
    expect((await repo.getAsset('1'))['name'], '支付宝');
    // 离线缓存:继承人 + 操作记录可读。
    expect(await repo.listInheritors(), hasLength(1));
    expect((await repo.listInheritors()).first['name'], '张三');
    expect(await repo.listLogs(), hasLength(1));
    expect((await repo.readLogsFromCache()).first['action'], contains('新增资产'));
    // 写操作不支持。
    await expectLater(
      repo.createAsset({'name': 'x'}),
      throwsA(isA<UnsupportedError>()),
    );
    await expectLater(
      repo.deleteAsset('1'),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test('离线仓库:writeLogsToCache 更新缓存日志,新实例可读回', () async {
    final repo = OfflineAssetRepository(masterKeyB64: key, vault: vault);
    expect(await repo.listLogs(), isEmpty);
    await repo.writeLogsToCache([
      {'kind': 'audit', 'action': '新增资产「A」', 'created_at': '2026-08-02 09:00:00'},
    ]);
    // 同一实例内存缓存已更新。
    expect(await repo.listLogs(), hasLength(1));
    // 新实例从磁盘读回。
    final repo2 = OfflineAssetRepository(masterKeyB64: key, vault: vault);
    expect((await repo2.readLogsFromCache()).first['action'], '新增资产「A」');
  });

  test('离线仓库:无缓存 → 空列表;未知资产 → 抛错', () async {
    final repo = OfflineAssetRepository(masterKeyB64: key, vault: vault);
    expect(await repo.listAssets(), isEmpty);
    await expectLater(
      repo.getAsset('nope'),
      throwsA(isA<StateError>()),
    );
  });
}

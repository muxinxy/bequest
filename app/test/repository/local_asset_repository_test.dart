import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/repository/local_asset_repository.dart';
import 'package:bequest/sync/local_vault.dart';

/// 本地库:纯文件 + crypto,临时目录注入,无插件依赖。
void main() {
  final key = base64.encode(List<int>.filled(32, 7));

  late Directory tempDir;
  late LocalVault vault;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('bequest_repo_test');
    vault = LocalVault(directory: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  LocalAssetRepository repo() =>
      LocalAssetRepository(masterKeyB64: key, vault: vault);

  test('分类:创建/列表/删除,删除后资产 category_id 置空', () async {
    final r = repo();
    final cat = await r.createCategory('房产');
    expect(cat['id'], isNotNull);
    expect(cat['created_at'], isNotNull);
    expect(await r.listCategories(), hasLength(1));

    final asset = await r.createAsset({
      'name': 'A房',
      'asset_type': 'physical',
      'category_id': cat['id'],
      'encrypted_data': 'blob',
    });
    expect(asset['category_id'], cat['id']);

    await r.deleteCategory('${cat['id']}');
    expect(await r.listCategories(), isEmpty);
    expect((await r.getAsset('${asset['id']}'))['category_id'], isNull);
  });

  test('资产:创建/读取/列表/更新/删除 往返', () async {
    final r = repo();
    final created = await r.createAsset({
      'name': '证券B',
      'asset_type': 'virtual',
      'encrypted_data': 'blob-1',
      'expiry_date': '2030-01-01',
    });
    final id = '${created['id']}';
    expect(id, startsWith('L'));
    expect(created['created_at'], isNotNull);
    expect(created['updated_at'], isNotNull);

    expect((await r.getAsset(id))['encrypted_data'], 'blob-1');
    expect(await r.listAssets(), hasLength(1));
    expect((await r.listAssets()).first['id'], id);

    final updated = await r.updateAsset(id, {
      'name': '证券B改',
      'encrypted_data': 'blob-2',
    });
    expect(updated['name'], '证券B改');
    expect((await r.getAsset(id))['encrypted_data'], 'blob-2');
    // 未覆盖字段保留。
    expect((await r.getAsset(id))['asset_type'], 'virtual');

    await r.deleteAsset(id);
    expect(await r.listAssets(), isEmpty);
    expect(() => r.getAsset(id), throwsStateError);
  });

  test('数据跨实例持久化(重新加载 vault)', () async {
    final r1 = repo();
    await r1.createCategory('数码');
    final a = await r1.createAsset({
      'name': 'BTC',
      'asset_type': 'virtual',
      'encrypted_data': 'x',
    });

    final r2 = repo(); // 同一目录,新实例。
    expect(await r2.listCategories(), hasLength(1));
    expect(await r2.listAssets(), hasLength(1));
    expect((await r2.getAsset('${a['id']}'))['name'], 'BTC');
  });

  test('旧版纯备份串 vault:不崩溃,按空库处理', () async {
    await vault.saveVault(
      '{"app":"bequest","type":"backup","version":1,"assets":[]}',
      key,
    );
    expect(await vault.readSalt(key), isNull);
    final data = await vault.loadLocalData(key);
    expect(data, isNotNull);
    expect(data!['assets'], isEmpty);
    expect(data['categories'], isEmpty);

    final r = repo();
    expect(await r.listAssets(), isEmpty);
    final created = await r.createAsset({'name': '新资产', 'asset_type': 'physical'});
    expect('${created['id']}', startsWith('L'));
  });

  test('salt 保存后可读取(跨设备恢复用)', () async {
    await vault.saveLocalData(
      {'schema': 1, 'assets': [], 'categories': []},
      key,
      salt: 'c2FsdA==',
    );
    expect(await vault.readSalt(key), 'c2FsdA==');
  });
}

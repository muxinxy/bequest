import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/models/asset.dart';
import 'package:bequest/repository/local_asset_repository.dart';
import 'package:bequest/sync/local_vault.dart';

/// 回归测试:真实设备"新建资产 → 返回主页 → 点进编辑页"链路。
///
/// 根因:主页 `_filteredAssets` 把资产经 `Asset.toJson()` 往返,
/// 而 `toJson` 丢掉了 `id`,导致列表里的资产 id 变为空串,
/// 编辑页 `getAsset('')` 抛 StateError,提示"资产不存在或本地数据异常"。
/// 修复:toJson/fromJson 互为逆,id 与 updated_at 随往返保留。
void main() {
  final key = base64.encode(List<int>.filled(32, 7));

  late Directory tempDir;
  late LocalVault vault;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('bequest_regression_test');
    vault = LocalVault(directory: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  LocalAssetRepository repo() =>
      LocalAssetRepository(masterKeyB64: key, vault: vault);

  test('回归:Asset.toJson/fromJson 往返必须保留 id(主页过滤依赖此不变式)', () {
    const asset = Asset(
      id: 'L17000000000001',
      name: '新资产',
      assetType: 'physical',
      categoryId: 'L17000000000000',
      encryptedData: 'blob',
      expiryDate: '2030-01-01',
      updatedAt: '2026-08-09 12:00:00',
    );
    final restored = Asset.fromJson(asset.toJson());
    expect(restored.id, asset.id,
        reason: 'toJson 丢弃 id 会让主页列表里的资产 id 变为空串,'
            '编辑页 getAsset(\'\') 必然抛 StateError');
    expect(restored.name, asset.name);
    expect(restored.updatedAt, asset.updatedAt);
  });

  test('回归:用户链路 — createAsset → 主页重载 → 过滤往返 → 编辑页 getAsset', () async {
    // 与真实设备一致:本地库在"设置主密码"时已初始化并带 salt。
    await vault.saveLocalData(
      {
        'schema': 1,
        'assets': <Map<String, dynamic>>[],
        'categories': <Map<String, dynamic>>[],
      },
      key,
      salt: 'c2FsdA==',
    );

    // 主页首次加载(仓库 A):FAB 新建资产。
    final repoA = repo();
    expect(await repoA.listAssets(), isEmpty);
    final created = await repoA.createAsset({
      'name': '新资产',
      'asset_type': 'physical',
      'encrypted_data': '本地加密内容',
    });
    final id = '${created['id']}';
    expect(id, startsWith('L'));

    // 主页重载:全新仓库 B(模拟 home 每次 _load 都新建 repo)。
    final repoB = repo();
    final listed = await repoB.listAssets();
    expect(listed.map((a) => '${a['id']}'), contains(id),
        reason: '主页重载后列表必须包含刚创建的资产');

    // home._filteredAssets 的等价往返:Asset → toJson → fromJson。
    final homeAsset = Asset.fromJson(listed.first);
    final filtered = Asset.fromJson(homeAsset.toJson());
    expect(filtered.id, id,
        reason: '主页过滤往返后 id 必须保留,否则编辑页 getAsset 抛 StateError');

    // 点进编辑页:getAsset 必须读回,否则页面提示"资产不存在或本地数据异常"。
    final full = await repoB.getAsset(filtered.id);
    expect(full['name'], '新资产');
    expect(full['encrypted_data'], '本地加密内容');
  });
}

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

  test('分类删除:moveTo 指定时资产移入目标分组(字符串 id),而非置空', () async {
    final r = repo();
    final cat = await r.createCategory('待删分组');
    final keep = await r.createCategory('保留分组');
    final keepId = '${keep['id']}';
    final asset = await r.createAsset({
      'name': '资产',
      'asset_type': 'physical',
      'category_id': cat['id'],
      'encrypted_data': 'blob',
    });

    // moveTo 用字符串分组 id(本地 id 为 'L<时间戳><序号>',int 转换会失效)。
    await r.deleteCategory('${cat['id']}', moveTo: keepId);
    expect(await r.listCategories(), hasLength(1));
    expect((await r.getAsset('${asset['id']}'))['category_id'], keepId);
  });

  test('moveAssets:字符串分组 id 移动到目标分组,而非误置未分类', () async {
    final r = repo();
    final cat = await r.createCategory('目标分组');
    final targetId = '${cat['id']}';
    // 本地分组 id 是 'L<时间戳><序号>' 字符串,int.tryParse 会失败——
    // 回归防护:接口按字符串传 id,本地实现直接匹配,不转 int。
    expect(targetId.startsWith('L'), isTrue);

    final a1 = await r.createAsset({
      'name': '未分类资产1',
      'asset_type': 'physical',
      'category_id': null,
      'encrypted_data': 'blob',
    });
    final a2 = await r.createAsset({
      'name': '已分类资产',
      'asset_type': 'physical',
      'category_id': targetId,
      'encrypted_data': 'blob',
    });

    final result = await r.moveAssets(['${a1['id']}'], targetId);
    expect(result['moved'], 1);
    expect((await r.getAsset('${a1['id']}'))['category_id'], targetId);
    // 未在列表中的资产不受影响。
    expect((await r.getAsset('${a2['id']}'))['category_id'], targetId);
  });

  test('分类:更新改名与改类型,id/created_at 保留', () async {
    final r = repo();
    final cat = await r.createCategory('房产');
    final id = '${cat['id']}';
    expect(cat['asset_type'], 'physical');

    final updated = await r.updateCategory(id, {
      'name': '不动产',
      'asset_type': 'virtual',
    });
    expect(updated['id'], id);
    expect(updated['name'], '不动产');
    expect(updated['asset_type'], 'virtual');
    expect(updated['created_at'], cat['created_at']);

    final list = await r.listCategories();
    expect(list, hasLength(1));
    expect(list.first['name'], '不动产');
    expect(list.first['asset_type'], 'virtual');

    // 仅改名不改类型:原类型保留。
    await r.updateCategory(id, {'name': '还是不动产'});
    expect((await r.listCategories()).first['asset_type'], 'virtual');

    expect(() => r.updateCategory('L999', {'name': 'x'}), throwsStateError);
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

  test('编辑流程端到端:新实例 listCategories+getAsset 往返,全程无网络', () async {
    // 模拟本地模式编辑资产:写入(建分类+建资产)→ 新实例读列表与详情 → 更新 → 再读。
    final r1 = repo();
    final cat = await r1.createCategory('房产');
    final a = await r1.createAsset({
      'name': '房产证',
      'asset_type': 'physical',
      'category_id': cat['id'],
      'encrypted_data': '本地加密内容',
      'expiry_date': '2030-01-01',
    });

    final r2 = repo(); // 编辑页视角:全新实例。
    final categories = await r2.listCategories();
    expect(categories, hasLength(1));
    expect(categories.first['name'], '房产');
    final full = await r2.getAsset('${a['id']}');
    expect(full['name'], '房产证');
    expect(full['category_id'], cat['id']);
    expect(full['encrypted_data'], '本地加密内容');
    expect(full['expiry_date'], '2030-01-01');

    // 保存编辑结果后,再用第三个实例读回。
    await r2.updateAsset('${a['id']}', {
      'name': '房产证(更新)',
      'encrypted_data': 'v2',
    });
    final r3 = repo();
    final saved = await r3.getAsset('${a['id']}');
    expect(saved['name'], '房产证(更新)');
    expect(saved['encrypted_data'], 'v2');
    // 未覆盖字段保留。
    expect(saved['category_id'], cat['id']);
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

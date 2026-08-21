import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/models/asset_filter.dart';

void main() {
  final assets = <Map<String, dynamic>>[
    {'id': '1', 'name': '北京房产', 'asset_type': 'physical', 'category_id': 'c1'},
    {'id': '2', 'name': 'BTC钱包', 'asset_type': 'virtual', 'category_id': 'c2'},
    {'id': '3', 'name': '花园洋房', 'asset_type': 'physical', 'category_id': null},
    {'id': '4', 'name': '股票账户', 'asset_type': 'virtual', 'category_id': 'c2'},
  ];

  test('类型过滤', () {
    expect(filterAssets(assets: assets, typeFilter: 'physical'), hasLength(2));
    expect(filterAssets(assets: assets, typeFilter: 'virtual'), hasLength(2));
  });

  test('分类过滤(按 id 精确匹配)', () {
    expect(filterAssets(assets: assets, categoryFilter: 'c2'), hasLength(2));
    expect(filterAssets(assets: assets, categoryFilter: 'c1'), hasLength(1));
  });

  test('未分组过滤', () {
    expect(
      filterAssets(assets: assets, categoryFilter: kUncategorizedFilter),
      hasLength(1),
    );
  });

  test('名称搜索不区分大小写', () {
    expect(filterAssets(assets: assets, search: '房'), hasLength(2));
    expect(filterAssets(assets: assets, search: 'btc'), hasLength(1));
    expect(filterAssets(assets: assets, search: ' 房 '), hasLength(2)); // 两侧空白忽略
    expect(filterAssets(assets: assets, search: '不存在'), isEmpty);
  });

  test('组合过滤(类型 + 分类 + 搜索)', () {
    expect(
      filterAssets(
        assets: assets,
        typeFilter: 'virtual',
        categoryFilter: 'c2',
        search: '账户',
      ),
      hasLength(1),
    );
    // 类型与分类冲突 → 空。
    expect(
      filterAssets(
        assets: assets,
        typeFilter: 'physical',
        categoryFilter: 'c2',
      ),
      isEmpty,
    );
  });
}

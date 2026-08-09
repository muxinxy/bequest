import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/models/category.dart';

void main() {
  test('Category.fromJson 解析 asset_type 与 is_preset(数字/布尔/缺省)', () {
    final c1 = Category.fromJson({
      'id': '1',
      'name': '房产',
      'asset_type': 'physical',
      'is_preset': 1,
      'created_at': '2026-01-01 00:00:00',
    });
    expect(c1.assetType, 'physical');
    expect(c1.isPreset, isTrue);
    expect(c1.createdAt, '2026-01-01 00:00:00');

    final c2 = Category.fromJson({
      'id': '2',
      'name': '银行账户',
      'asset_type': 'virtual',
      'is_preset': true,
    });
    expect(c2.assetType, 'virtual');
    expect(c2.isPreset, isTrue);

    // 缺省:physical / 非预设。
    final c3 = Category.fromJson({'id': '3', 'name': '自建'});
    expect(c3.assetType, 'physical');
    expect(c3.isPreset, isFalse);
  });
}

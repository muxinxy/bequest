import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/models/asset.dart';

void main() {
  test('Asset toJson→fromJson 往返保留 id 与 updated_at(主页筛选链路依赖)', () {
    const asset = Asset(
      id: 'L12345678901',
      name: '房产证',
      assetType: 'physical',
      categoryId: 'c1',
      encryptedData: 'blob',
      expiryDate: '2030-01-01',
      updatedAt: '2026-08-09 10:00:00',
    );

    final roundTripped = Asset.fromJson(asset.toJson());

    expect(roundTripped.id, 'L12345678901', reason: 'id 丢失会导致编辑页 getAsset("") 报"资产不存在"');
    expect(roundTripped.name, '房产证');
    expect(roundTripped.assetType, 'physical');
    expect(roundTripped.categoryId, 'c1');
    expect(roundTripped.encryptedData, 'blob');
    expect(roundTripped.expiryDate, '2030-01-01');
    expect(roundTripped.updatedAt, '2026-08-09 10:00:00');
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/models/entitlements.dart';

/// 三层权益矩阵常量。
void main() {
  test('访客 guest', () {
    expect(Entitlements.guest.label, '访客');
    expect(Entitlements.guest.assetLimit, 20);
    expect(Entitlements.guest.cloudSync, isFalse);
    expect(Entitlements.guest.inheritance, isFalse);
    expect(Entitlements.guest.reminderChannels, 1);
    expect(Entitlements.guest.customTemplates, isFalse);
    expect(Entitlements.guest.exportExcel, isFalse);
    expect(Entitlements.guest.offlineMode, isTrue);
  });

  test('免费用户 free', () {
    expect(Entitlements.free.label, '免费用户');
    expect(Entitlements.free.assetLimit, 50);
    expect(Entitlements.free.cloudSync, isTrue);
    expect(Entitlements.free.inheritance, isTrue);
    expect(Entitlements.free.reminderChannels, 2);
    expect(Entitlements.free.customTemplates, isTrue);
    expect(Entitlements.free.exportExcel, isFalse);
    expect(Entitlements.free.offlineMode, isTrue);
  });

  test('会员 member', () {
    expect(Entitlements.member.label, '会员');
    expect(Entitlements.member.assetLimit, isNull); // null = 不限
    expect(Entitlements.member.cloudSync, isTrue);
    expect(Entitlements.member.inheritance, isTrue);
    expect(Entitlements.member.reminderChannels, 4);
    expect(Entitlements.member.customTemplates, isTrue);
    expect(Entitlements.member.exportExcel, isTrue);
    expect(Entitlements.member.offlineMode, isTrue);
  });

  test('forTier 层级映射', () {
    expect(Entitlements.forTier(null), Entitlements.guest);
    expect(Entitlements.forTier('guest'), Entitlements.guest);
    expect(Entitlements.forTier('member'), Entitlements.member);
    expect(Entitlements.forTier('free'), Entitlements.free);
    expect(Entitlements.forTier('unknown'), Entitlements.free);
  });

  test('forJwtAndTier 结合登录态', () {
    // 未登录:无论 tier 一律访客。
    expect(Entitlements.forJwtAndTier(hasJwt: false, tier: null), Entitlements.guest);
    expect(Entitlements.forJwtAndTier(hasJwt: false, tier: 'member'), Entitlements.guest);
    // 已登录:tier 未知按免费用户;member 显式会员。
    expect(Entitlements.forJwtAndTier(hasJwt: true, tier: null), Entitlements.free);
    expect(Entitlements.forJwtAndTier(hasJwt: true, tier: 'member'), Entitlements.member);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/app_lock_policy.dart';

void main() {
  group('shouldLockOnColdStart', () {
    test('锁已启用且有凭据(jwt 或主密钥)→ 锁定', () {
      expect(
        shouldLockOnColdStart(lockEnabled: true, hasCredential: true),
        isTrue,
      );
    });

    test('锁已启用但无凭据(已退出登录)→ 不锁', () {
      expect(
        shouldLockOnColdStart(lockEnabled: true, hasCredential: false),
        isFalse,
      );
    });

    test('未启用锁 → 不锁', () {
      expect(
        shouldLockOnColdStart(lockEnabled: false, hasCredential: true),
        isFalse,
      );
      expect(
        shouldLockOnColdStart(lockEnabled: false, hasCredential: false),
        isFalse,
      );
    });
  });
}

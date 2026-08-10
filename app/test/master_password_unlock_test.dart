import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/crypto/attempt_guard.dart';
import 'package:bequest/crypto/key_derivation.dart';
import 'package:bequest/crypto/master_password.dart';
import 'package:bequest/storage/secure_store.dart';

/// 回归:锁屏"用主密码解锁"的纯逻辑路径
/// (guard 检查 → verifyMasterPassword → recordSuccess/recordFailure)。
void main() {
  const salt = 'c2FsdA=='; // base64("salt")
  const correct = 'correct-password';
  late SecureStore store;

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    store = SecureStore();
  });

  AttemptGuard guard(String prefix) =>
      AttemptGuard(store: store, prefix: prefix);

  Future<void> seed() async {
    await store.saveMasterSalt(salt);
    await store.saveMasterKey(deriveMasterKey(correct, salt));
  }

  test('正确主密码解锁:返回 true 并清零主密码限流计数', () async {
    await seed();
    final master = guard('master');
    // 先制造 4 次失败,验证解锁成功会清零计数。
    for (var i = 0; i < 4; i++) {
      await master.recordFailure();
    }
    expect(
      await masterPasswordUnlock(
        store: store,
        guard: master,
        password: correct,
      ),
      isTrue,
    );
    expect(await master.checkLocked(), isFalse);
    // 计数已清零:再来一次失败不应立刻锁定。
    await master.recordFailure();
    expect(await master.checkLocked(), isFalse);
  });

  test('错误主密码:返回 false 并累计失败,5 次后进入锁定', () async {
    await seed();
    final master = guard('master');
    for (var i = 0; i < 4; i++) {
      expect(
        await masterPasswordUnlock(
          store: store,
          guard: master,
          password: 'wrong',
        ),
        isFalse,
      );
      expect(await master.checkLocked(), isFalse, reason: '未达阈值不锁定');
    }
    expect(
      await masterPasswordUnlock(
        store: store,
        guard: master,
        password: 'wrong',
      ),
      isFalse,
    );
    expect(await master.checkLocked(), isTrue, reason: '第 5 次失败进入锁定');
  });

  test('主密码限流中:正确密码也返回 false、不累计计数,且不影响 lock(PIN/图案)限流', () async {
    await seed();
    final master = guard('master');
    final lock = guard('lock');
    for (var i = 0; i < 5; i++) {
      await master.recordFailure();
    }
    expect(await master.checkLocked(), isTrue);
    final failuresBefore = await store.readInt('bequest_master_failures');
    expect(
      await masterPasswordUnlock(
        store: store,
        guard: master,
        password: correct,
      ),
      isFalse,
    );
    // 锁定期间不额外累计失败。
    expect(await store.readInt('bequest_master_failures'), failuresBefore);
    // PIN/图案(lock 前缀)限流与主密码完全独立,仍然可用。
    expect(await lock.checkLocked(), isFalse);
    await lock.recordFailure();
    expect(await lock.checkLocked(), isFalse);
  });

  test('盐缺失(旧账号未保存)返回 false 且不抛异常', () async {
    final master = guard('master');
    expect(
      await masterPasswordUnlock(
        store: store,
        guard: master,
        password: correct,
      ),
      isFalse,
    );
  });
}

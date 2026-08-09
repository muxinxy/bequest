import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/crypto/attempt_guard.dart';
import 'package:bequest/storage/secure_store.dart';

void main() {
  late SecureStore store;

  setUp(() {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    store = SecureStore();
  });

  AttemptGuard guard(String prefix) =>
      AttemptGuard(store: store, prefix: prefix);

  test('连续 5 次失败后进入锁定,remainingSeconds 开始倒计时', () async {
    final g = guard('lock');
    expect(await g.checkLocked(), isFalse);
    for (var i = 0; i < 4; i++) {
      await g.recordFailure();
      expect(await g.checkLocked(), isFalse, reason: '未达阈值不锁定');
    }
    await g.recordFailure(); // 第 5 次 → 锁定。
    expect(await g.checkLocked(), isTrue);
    expect(
      await g.remainingSeconds(),
      inInclusiveRange(1, AttemptGuard.lockDuration.inSeconds),
    );
  });

  test('锁定期间失败不累计,不延长锁', () async {
    final g = guard('lock');
    for (var i = 0; i < 5; i++) {
      await g.recordFailure();
    }
    expect(await g.checkLocked(), isTrue);
    final before = await g.remainingSeconds();
    await g.recordFailure(); // 锁定中:不应累计失败。
    expect(await g.checkLocked(), isTrue);
    final after = await g.remainingSeconds();
    expect(after, lessThanOrEqualTo(before));
  });

  test('recordSuccess 清零计数与锁,计数重新开始', () async {
    final g = guard('master');
    for (var i = 0; i < 5; i++) {
      await g.recordFailure();
    }
    expect(await g.checkLocked(), isTrue);
    await g.recordSuccess();
    expect(await g.checkLocked(), isFalse);
    expect(await g.remainingSeconds(), 0);
    // 清零后需重新累计 5 次才锁定。
    for (var i = 0; i < 4; i++) {
      await g.recordFailure();
    }
    expect(await g.checkLocked(), isFalse);
    await g.recordFailure();
    expect(await g.checkLocked(), isTrue);
  });

  test('已过期的锁自动清理', () async {
    final g = guard('lock');
    await store.writeInt(
      'bequest_lock_locked_until',
      DateTime.now().millisecondsSinceEpoch - 1000,
    );
    expect(await g.checkLocked(), isFalse);
    expect(await g.remainingSeconds(), 0);
    // 计数也随锁一起清零。
    await g.recordFailure();
    expect(await g.checkLocked(), isFalse);
  });

  test('lock 与 master 两个限流实例互不影响', () async {
    final lock = guard('lock');
    final master = guard('master');
    for (var i = 0; i < 5; i++) {
      await lock.recordFailure();
    }
    expect(await lock.checkLocked(), isTrue);
    expect(await master.checkLocked(), isFalse);
    expect(await master.remainingSeconds(), 0);
  });

  test('主密码提示语往返(save/read/clear)', () async {
    expect(await store.readMasterHint(), isNull);
    await store.saveMasterHint('我的宠物名字');
    expect(await store.readMasterHint(), '我的宠物名字');
    await store.saveMasterHint('第二个提示');
    expect(await store.readMasterHint(), '第二个提示');
    await store.deleteKey('bequest_master_hint');
    expect(await store.readMasterHint(), isNull);
  });
}

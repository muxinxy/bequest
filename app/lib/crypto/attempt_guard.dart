import '../storage/secure_store.dart';

/// 失败限流:连续 [maxFailures] 次失败后锁定 [lockDuration],期间拒绝尝试。
/// 成功解锁或锁超时后清零。纯逻辑 + 注入 SecureStore,便于单测。
class AttemptGuard {
  AttemptGuard({required this.store, required String prefix})
    : _failuresKey = 'bequest_${prefix}_failures',
      _lockedUntilKey = 'bequest_${prefix}_locked_until';

  /// 连续失败次数阈值;达到后进入锁定。
  static const int maxFailures = 5;

  /// 锁定时长:固定 60 秒。
  // ponytail: 固定 60s 而非指数退避,需求仅要求防暴力尝试,够用;
  // 若需更强防护再改为 30s * 2^(failures-5) 退避。
  static const Duration lockDuration = Duration(seconds: 60);

  final SecureStore store;
  final String _failuresKey;
  final String _lockedUntilKey;

  /// 是否锁定中;已过期的锁自动清零。
  Future<bool> checkLocked() async {
    final until = await store.readInt(_lockedUntilKey);
    if (until == null) return false;
    if (until > DateTime.now().millisecondsSinceEpoch) return true;
    await clearLock();
    return false;
  }

  /// 记录一次失败;达到阈值即锁定。锁定期间不累计失败。
  Future<void> recordFailure() async {
    if (await checkLocked()) return;
    final failures = (await store.readInt(_failuresKey) ?? 0) + 1;
    await store.writeInt(_failuresKey, failures);
    if (failures >= maxFailures) {
      final until =
          DateTime.now().millisecondsSinceEpoch + lockDuration.inMilliseconds;
      await store.writeInt(_lockedUntilKey, until);
    }
  }

  /// 解锁成功:清零计数与锁。
  Future<void> recordSuccess() async {
    await store.deleteKey(_failuresKey);
    await store.deleteKey(_lockedUntilKey);
  }

  /// 剩余锁定秒数;未锁定返回 0。
  Future<int> remainingSeconds() async {
    final until = await store.readInt(_lockedUntilKey);
    if (until == null) return 0;
    final remainMs = until - DateTime.now().millisecondsSinceEpoch;
    if (remainMs <= 0) {
      await clearLock();
      return 0;
    }
    return (remainMs / 1000).ceil();
  }

  Future<void> clearLock() async {
    await store.deleteKey(_failuresKey);
    await store.deleteKey(_lockedUntilKey);
  }
}

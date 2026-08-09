import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/crypto/pattern_hash.dart';
import 'package:bequest/storage/secure_store.dart';

void main() {
  group('hashPattern/verifyPattern', () {
    test('同序列同盐哈希稳定,不同盐不同', () {
      expect(
        hashPattern([0, 1, 2, 5], 'saltA'),
        hashPattern([0, 1, 2, 5], 'saltA'),
      );
      expect(
        hashPattern([0, 1, 2, 5], 'saltA'),
        isNot(hashPattern([0, 1, 2, 5], 'saltB')),
      );
    });

    test('不同序列哈希不同', () {
      expect(
        hashPattern([0, 1, 2, 5], 'saltA'),
        isNot(hashPattern([0, 2, 1, 5], 'saltA')),
      );
    });

    test('verifyPattern 正确序列通过,错误/过短序列不通过', () {
      const salt = 'saltA';
      final hash = hashPattern([0, 1, 2, 5], salt);
      expect(verifyPattern([0, 1, 2, 5], salt, hash), isTrue);
      expect(verifyPattern([0, 1, 2, 8], salt, hash), isFalse);
      expect(verifyPattern([0, 1, 2], salt, hash), isFalse);
      expect(verifyPattern([0, 1, 2, 5], 'other', hash), isFalse);
    });
  });

  group('shouldRecordPatternFailure(限流接线判定)', () {
    const salt = 'saltA';
    final hash = hashPattern([0, 1, 2, 5], salt);

    test('正确图案 → false(记成功)', () {
      expect(
        shouldRecordPatternFailure(salt: salt, hash: hash, dots: [0, 1, 2, 5]),
        isFalse,
      );
    });

    test('错误图案(≥4 点)→ true(记失败)', () {
      expect(
        shouldRecordPatternFailure(salt: salt, hash: hash, dots: [0, 1, 2, 8]),
        isTrue,
      );
    });

    test('短图案(<4 点)即使与哈希无关也记失败', () {
      expect(
        shouldRecordPatternFailure(salt: salt, hash: hash, dots: [0, 1, 2]),
        isTrue,
      );
      expect(
        shouldRecordPatternFailure(salt: salt, hash: hash, dots: [0]),
        isTrue,
      );
    });

    test('盐或哈希缺失(损坏状态)一律记失败,不崩溃', () {
      expect(
        shouldRecordPatternFailure(salt: null, hash: hash, dots: [0, 1, 2, 5]),
        isTrue,
      );
      expect(
        shouldRecordPatternFailure(salt: salt, hash: null, dots: [0, 1, 2, 5]),
        isTrue,
      );
      expect(
        shouldRecordPatternFailure(
          salt: '',
          hash: '',
          dots: [0, 1, 2, 5],
        ),
        isTrue,
      );
    });
  });

  group('secure_store 锁定时钟与图案键', () {
    setUp(() {
      FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform(
        {},
      );
    });

    test('timing 默认 exit,非法值回落 exit', () async {
      final store = SecureStore();
      expect(await store.readLockTiming(), 'exit');
      await store.setLockTiming('timeout');
      expect(await store.readLockTiming(), 'timeout');
      await store.setLockTiming('garbage');
      expect(await store.readLockTiming(), 'exit');
    });

    test('timeout 默认 5,1-60 往返,越界回落默认', () async {
      final store = SecureStore();
      expect(await store.readLockTimeoutMinutes(), 5);
      await store.setLockTimeoutMinutes(30);
      expect(await store.readLockTimeoutMinutes(), 30);
      await store.setLockTimeoutMinutes(1);
      expect(await store.readLockTimeoutMinutes(), 1);
      await store.setLockTimeoutMinutes(0);
      expect(await store.readLockTimeoutMinutes(), 5);
      await store.setLockTimeoutMinutes(61);
      expect(await store.readLockTimeoutMinutes(), 5);
    });

    test('pattern 哈希/盐写入读取与清除', () async {
      final store = SecureStore();
      expect(await store.readPatternHash(), isNull);
      await store.savePatternSalt('saltX');
      await store.savePatternHash('hashY');
      expect(await store.readPatternSalt(), 'saltX');
      expect(await store.readPatternHash(), 'hashY');
      await store.clearPattern();
      expect(await store.readPatternSalt(), isNull);
      expect(await store.readPatternHash(), isNull);
    });
  });
}

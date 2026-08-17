import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/sync/sync_provider.dart';

void main() {
  group('withRetry', () {
    test('网络错误重试 3 次后成功', () async {
      var calls = 0;
      final result = await withRetry(() async {
        calls++;
        if (calls < 3) throw TimeoutException('timeout');
        return 'ok';
      });
      expect(result, 'ok');
      expect(calls, 3);
    });

    test('SyncException 不重试(业务错误)', () async {
      var calls = 0;
      await expectLater(
        withRetry(() async {
          calls++;
          throw SyncException('认证失败');
        }),
        throwsA(isA<SyncException>()),
      );
      expect(calls, 1); // 只调一次。
    });

    test('持续失败抛最后异常', () async {
      var calls = 0;
      await expectLater(
        withRetry(() async {
          calls++;
          throw TimeoutException('always');
        }),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls, 3);
    });
  });
}

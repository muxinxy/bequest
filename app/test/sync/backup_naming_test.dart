import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/sync/backup_naming.dart';

void main() {
  group('buildBackupFileName', () {
    test('用户名+设备名+时间戳拼接,json 后缀', () {
      expect(
        buildBackupFileName(
          username: 'alice',
          deviceName: 'Pixel-8',
          timestamp: '20260812_100000',
        ),
        'bequest_alice_Pixel-8_20260812_100000.json',
      );
    });

    test('特殊字符清洗为下划线,空用户名/设备名跳过对应段', () {
      // 中文/空格/!均不在 [A-Za-z0-9_-] 内 → 各替换为一个下划线。
      expect(
        buildBackupFileName(
          username: '张 三!',
          deviceName: '',
          timestamp: '20260812_100000',
        ),
        'bequest___20260812_100000.json',
      );
      expect(
        buildBackupFileName(
          username: '',
          deviceName: '',
          timestamp: '20260812_100000',
        ),
        'bequest_20260812_100000.json',
      );
    });
  });
}

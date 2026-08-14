import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/sync/auto_backup.dart';

void main() {
  group('AutoBackup 配置解析', () {
    test('intervalKeyOf / maxCountOf 默认与非法值兜底', () {
      expect(AutoBackupScheduler.intervalKeyOf({}), 'off');
      expect(
        AutoBackupScheduler.intervalKeyOf({'auto_backup_interval': '30m'}),
        '30m',
      );
      expect(AutoBackupScheduler.maxCountOf({}), 3);
      expect(
        AutoBackupScheduler.maxCountOf({'auto_backup_max': '10'}),
        10,
      );
      // 非法值回退默认 3。
      expect(
        AutoBackupScheduler.maxCountOf({'auto_backup_max': '999'}),
        3,
      );
    });

    test('间隔表包含要求的全部档位', () {
      expect(kAutoBackupIntervals.keys, containsAll([
        'off', '1m', '5m', '15m', '30m', '1h', '2h', '6h', '12h', '24h',
        'on_open', 'on_exit',
      ]));
      expect(kAutoBackupMaxCounts, [1, 3, 5, 10, 20, 50]);
      expect(kAutoBackupIntervals['5m'], const Duration(minutes: 5));
      expect(kAutoBackupIntervals['24h'], const Duration(hours: 24));
    });
  });
}

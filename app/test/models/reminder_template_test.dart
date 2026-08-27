import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/models/reminder_template.dart';

void main() {
  group('ReminderTemplate.fromJson', () {
    test('解析 type 字段', () {
      final t = ReminderTemplate.fromJson({
        'id': 1,
        'name': '到期提醒',
        'type': 'escalation',
        'is_preset': 1,
      });
      expect(t.type, 'escalation');
      expect(t.isPreset, isTrue);
    });

    test('type 缺失时默认 expiry', () {
      final t = ReminderTemplate.fromJson({'id': 2, 'name': 'x'});
      expect(t.type, 'expiry');
    });

    test('解析 is_default 字段', () {
      final t = ReminderTemplate.fromJson({
        'id': 3,
        'name': 'x',
        'is_preset': 0,
        'is_default': 1,
      });
      expect(t.isPreset, isFalse);
      expect(t.isDefault, isTrue);
    });
  });
}

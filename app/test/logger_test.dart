import 'dart:io';

import 'package:bequest/logger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bequest_logger_test');
    Logger.instance.directoryOverride = () async => tempDir.path;
    await Logger.instance.clear();
  });

  tearDown(() async {
    Logger.instance.directoryOverride = null;
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // 清理失败不影响断言。
    }
  });

  test('d/e 写入,readLog 返回完整内容', () async {
    Logger.instance.d('first debug');
    Logger.instance.e('first error');
    await Logger.instance.flush();

    final log = await Logger.instance.readLog();
    expect(log, contains('[D] first debug'));
    expect(log, contains('[E] first error'));
    // 行首带时间戳 [yyyy-MM-dd HH:mm:ss.SSS]。
    expect(RegExp(r'^\[\d{4}-\d{2}-\d{2} ').hasMatch(log), isTrue);
  });

  test('多次追加保持顺序', () async {
    Logger.instance.d('line 1');
    Logger.instance.d('line 2');
    Logger.instance.e('line 3');
    await Logger.instance.flush();

    final log = await Logger.instance.readLog();
    expect(log.indexOf('line 1'), lessThan(log.indexOf('line 2')));
    expect(log.indexOf('line 2'), lessThan(log.indexOf('line 3')));
  });

  test('超过 256KB 上限时只保留末尾 ~64KB', () async {
    Logger.instance.d('A' * 200000); // ~200KB
    await Logger.instance.flush();
    final before = await Logger.instance.readLog();
    final firstLine = before.substring(0, before.indexOf('\n'));
    expect(before, contains('A' * 100));

    Logger.instance.d('B' * 200000); // 追加后必超限
    await Logger.instance.flush();
    final after = await Logger.instance.readLog();
    expect(after, contains('B'));
    // 总量 ~256KB 级(保留旧 64KB + 本次 ~200KB 行)。
    expect(after.length, lessThan(300 * 1024));
    // 旧内容头部(首行时间戳)已被裁掉,只留末尾 ~64KB。
    expect(after.contains(firstLine), isFalse);
    expect(after.indexOf('B' * 10), lessThan(70 * 1024));
    expect(after.contains('B' * 100), isTrue);
  });

  test('clear 后 readLog 为空,可继续写入', () async {
    Logger.instance.d('to be cleared');
    await Logger.instance.flush();
    expect(await Logger.instance.readLog(), isNotEmpty);

    await Logger.instance.clear();
    expect(await Logger.instance.readLog(), isEmpty);

    Logger.instance.d('after clear');
    await Logger.instance.flush();
    expect(await Logger.instance.readLog(), contains('after clear'));
  });

  test('日志文件不存在时 readLog 返回空串', () async {
    expect(await Logger.instance.readLog(), isEmpty);
  });
}

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 轻量文件日志:追加写入 应用文档目录/logs/app.log。
/// 所有 IO 失败静默吞掉,绝不影响业务。供"关于"页导出排查问题。
class Logger {
  Logger._();

  static final Logger instance = Logger._();

  /// 测试注入:返回日志目录路径;为 null 时用 getApplicationDocumentsDirectory。
  Future<String> Function()? directoryOverride;

  static const int _maxBytes = 256 * 1024; // 文件上限 ~256KB
  static const int _keepBytes = 64 * 1024; // 超限时仅保留末尾 ~64KB

  /// 串行写队列:保证顺序,也便于测试 await [flush]。
  Future<void> _pending = Future.value();

  void d(String msg) => _enqueue('D', msg);

  void e(String msg) => _enqueue('E', msg);

  void _enqueue(String level, String msg) {
    _pending = _pending.then((_) => _append(level, msg));
  }

  /// 等待队列中的写操作全部完成(测试用)。
  Future<void> flush() => _pending;

  Future<File> _logFile() async {
    final dir = directoryOverride != null
        ? await directoryOverride!()
        : (await getApplicationDocumentsDirectory()).path;
    return File('$dir${Platform.pathSeparator}logs'
        '${Platform.pathSeparator}app.log');
  }

  Future<void> _append(String level, String msg) async {
    try {
      final now = DateTime.now();
      String pad(int n, [int w = 2]) => n.toString().padLeft(w, '0');
      final line = '[${now.year}-${pad(now.month)}-${pad(now.day)} '
          '${pad(now.hour)}:${pad(now.minute)}:${pad(now.second)}.'
          '${pad(now.millisecond, 3)}] [$level] $msg\n';
      final file = await _logFile();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final existing = await file.exists() ? await file.readAsString() : '';
      var content = existing;
      if (content.length + line.length > _maxBytes) {
        // 超限:丢旧保新,只留末尾 64KB。
        content = content.length > _keepBytes
            ? content.substring(content.length - _keepBytes)
            : '';
      }
      await file.writeAsString('$content$line', flush: true);
    } catch (_) {
      // 日志失败静默,不影响业务。
    }
  }

  /// 读取完整日志内容(用于导出);文件不存在返回空串。
  Future<String> readLog() async {
    try {
      final file = await _logFile();
      if (!await file.exists()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  Future<void> clear() async {
    try {
      final file = await _logFile();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 静默。
    }
  }
}

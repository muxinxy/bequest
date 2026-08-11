import 'platform/string_store.dart';
import 'platform/string_store_io.dart'
    if (dart.library.js_interop) 'platform/string_store_web.dart';

/// 轻量日志:追加写入 应用文档目录/logs/app.log(VM)或 localStorage(Web)。
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

  /// 平台存储:VM 用文件(logs/app.log),Web 用 localStorage。
  StringStore get _store => makeStringStore(
    fileName: 'logs/app.log',
    directoryProvider: directoryOverride,
  );

  void d(String msg) => _enqueue('D', msg);

  void e(String msg) => _enqueue('E', msg);

  void _enqueue(String level, String msg) {
    _pending = _pending.then((_) => _append(level, msg));
  }

  /// 等待队列中的写操作全部完成(测试用)。
  Future<void> flush() => _pending;

  Future<void> _append(String level, String msg) async {
    try {
      final now = DateTime.now();
      String pad(int n, [int w = 2]) => n.toString().padLeft(w, '0');
      final line = '[${now.year}-${pad(now.month)}-${pad(now.day)} '
          '${pad(now.hour)}:${pad(now.minute)}:${pad(now.second)}.'
          '${pad(now.millisecond, 3)}] [$level] $msg\n';
      final existing = await _store.read() ?? '';
      var content = existing;
      if (content.length + line.length > _maxBytes) {
        // 超限:丢旧保新,只留末尾 64KB。
        content = content.length > _keepBytes
            ? content.substring(content.length - _keepBytes)
            : '';
      }
      await _store.write('$content$line');
    } catch (_) {
      // 日志失败静默,不影响业务。
    }
  }

  /// 读取完整日志内容(用于导出);文件不存在返回空串。
  Future<String> readLog() async {
    try {
      return await _store.read() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> clear() async {
    try {
      await _store.delete();
    } catch (_) {
      // 静默。
    }
  }
}

/// 时间格式化公共工具。
///
/// 服务端时间均为 UTC 的 'YYYY-MM-DD HH:MM:SS'(SQLite datetime('now'),
/// 无时区标记)。Dart 的 DateTime.parse 对无时区字符串按本地时间解析,
/// 必须先补 'Z' 再 toLocal 才是正确的 UTC→本地转换。
library;

/// 将服务端 UTC 时间串('YYYY-MM-DD HH:MM:SS' 或 ISO8601)转为客户端本地时区显示。
/// 解析失败或为空返回 [fallback](默认原串)。
String formatServerTime(String? utc, {String? fallback}) {
  if (utc == null || utc.isEmpty) return fallback ?? '';
  final dt = DateTime.tryParse(utc.endsWith('Z') ? utc : '${utc}Z');
  if (dt == null) return fallback ?? utc;
  final local = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

import 'dart:html' as html;
import 'dart:typed_data';
import 'dart:convert';

/// Web:触发浏览器下载(share API 不支持文件)。
Future<bool> shareTextFile(
  String fileName,
  String content,
  String shareText,
) async {
  try {
    final blob = html.Blob([Uint8List.fromList(utf8.encode(content))]);
    return _downloadBlob(fileName, blob);
  } catch (_) {
    return false;
  }
}

/// Web:下载二进制内容(Excel 等)。
Future<bool> shareBytesFile(
  String fileName,
  List<int> bytes,
  String shareText,
) async {
  try {
    final blob = html.Blob([Uint8List.fromList(bytes)]);
    return _downloadBlob(fileName, blob);
  } catch (_) {
    return false;
  }
}

bool _downloadBlob(String fileName, html.Blob blob) {
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..download = fileName
    ..style.display = 'none';
  html.document.body!.children.add(anchor);
  anchor.click();
  anchor.remove();
  html.Url.revokeObjectUrl(url);
  return true;
}

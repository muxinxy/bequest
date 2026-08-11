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
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..download = fileName
      ..style.display = 'none';
    html.document.body!.children.add(anchor);
    anchor.click();
    anchor.remove();
    html.Url.revokeObjectUrl(url);
    return true;
  } catch (_) {
    return false;
  }
}

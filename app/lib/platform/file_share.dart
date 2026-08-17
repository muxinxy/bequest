/// 平台无关的文本文件分享/下载:
/// - VM:写入临时文件后调系统分享面板(share_plus);
/// - Web:触发浏览器下载(share API 不支持文件,退化为下载)。
library;

import 'file_share_io.dart'
    if (dart.library.js_interop) 'file_share_web.dart' as impl;

/// 分享 [content] 为文件,文件名 [fileName];[shareText] 为分享文案(仅 VM 用)。
/// 失败返回 false(调用方自行提示)。
Future<bool> shareTextFile(
  String fileName,
  String content,
  String shareText,
) =>
    impl.shareTextFile(fileName, content, shareText);

/// 分享字节内容为文件(如 Excel 二进制)。
Future<bool> shareBytesFile(
  String fileName,
  List<int> bytes,
  String shareText,
) =>
    impl.shareBytesFile(fileName, bytes, shareText);

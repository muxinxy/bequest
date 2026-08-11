import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// VM:写临时文件 + 系统分享面板。
Future<bool> shareTextFile(
  String fileName,
  String content,
  String shareText,
) async {
  try {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(content);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], text: shareText),
    );
    return true;
  } catch (_) {
    return false;
  }
}

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'string_store.dart';

/// 文件实现的字符串存储。默认落应用文档目录,测试可注入目录。
class FileStringStore implements StringStore {
  FileStringStore({this.fileName = 'data.txt', this.directoryProvider});

  /// 文件名(子目录如 logs/app.log 也支持)。
  final String fileName;

  /// 测试可注入目录(懒求值);为 null 时用 getApplicationDocumentsDirectory。
  final Future<String> Function()? directoryProvider;

  Future<File> _file() async {
    final dir = directoryProvider != null
        ? await directoryProvider!()
        : (await getApplicationDocumentsDirectory()).path;
    return File('$dir/$fileName');
  }

  @override
  Future<String?> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(value, flush: true);
  }

  @override
  Future<void> delete() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 静默。
    }
  }
}

/// 平台工厂:创建文件实现的存储。
StringStore makeStringStore({
  required String fileName,
  Future<String> Function()? directoryProvider,
}) =>
    FileStringStore(
      fileName: fileName,
      directoryProvider: directoryProvider,
    );

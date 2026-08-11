import 'dart:html' as html;

import 'string_store.dart';

/// Web 实现的字符串存储:localStorage。
class WebStringStore implements StringStore {
  WebStringStore({this.fileName = 'data.txt', this.directoryProvider});

  /// 键名(与文件路径对应,保持跨平台存储键一致)。
  final String fileName;

  /// Web 无目录概念,仅保持构造签名一致。
  final Future<String> Function()? directoryProvider;

  String get _key => 'bequest:$fileName';

  @override
  Future<String?> read() async => html.window.localStorage[_key];

  @override
  Future<void> write(String value) async =>
      html.window.localStorage[_key] = value;

  @override
  Future<void> delete() async => html.window.localStorage.remove(_key);
}

/// 平台工厂:创建 localStorage 实现的存储。
StringStore makeStringStore({
  required String fileName,
  Future<String> Function()? directoryProvider,
}) =>
    WebStringStore(fileName: fileName, directoryProvider: directoryProvider);

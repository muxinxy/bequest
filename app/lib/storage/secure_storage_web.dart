import 'dart:html' as html;

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

/// Web 安全存储:localStorage 裸存(端到端加密的值,明文存可接受)。
/// 官方 web 实现依赖 WebCrypto,HTTP 局域网(非 secure context)下不可用,
/// 会导致注册/登录后写存储抛异常——见 ADR-13。
class WebSecureStoragePlatform extends FlutterSecureStoragePlatform {
  static const _prefix = 'bequest_secure_';

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    html.window.localStorage[_prefix + key] = value;
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async =>
      html.window.localStorage[_prefix + key];

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      html.window.localStorage.containsKey(_prefix + key);

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async =>
      html.window.localStorage.remove(_prefix + key);

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async {
    final map = <String, String>{};
    html.window.localStorage.forEach((k, v) {
      if (k.startsWith(_prefix)) map[k.substring(_prefix.length)] = v;
    });
    return map;
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    final toRemove = <String>[];
    html.window.localStorage.forEach((k, _) {
      if (k.startsWith(_prefix)) toRemove.add(k);
    });
    for (final k in toRemove) {
      html.window.localStorage.remove(k);
    }
  }
}

/// Web 启动初始化:用 localStorage 实现替换全局 secure storage platform。
void initPlatformSecureStorage() {
  FlutterSecureStoragePlatform.instance = WebSecureStoragePlatform();
}

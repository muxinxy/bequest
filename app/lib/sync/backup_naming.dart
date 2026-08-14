import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

import '../storage/secure_store.dart';

/// 备份文件名生成:bequest_<用户名>_<设备名>_<时间戳>.json。
/// 纯函数便于测试;用户名/设备名会做安全清洗(仅保留字母数字_-)。
String buildBackupFileName({
  required String username,
  required String deviceName,
  required String timestamp,
}) {
  String clean(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_').replaceAll(RegExp(r'_+'), '_');
  final user = clean(username);
  final device = clean(deviceName);
  final parts = [
    'bequest',
    if (user.isNotEmpty) user,
    if (device.isNotEmpty) device,
    timestamp,
  ];
  return '${parts.join('_')}.json';
}

/// 设备名:优先 Platform.localHostname,失败回退 'device';
/// web 端无 dart:io,回退 'web'。
String deviceName() {
  try {
    if (kIsWeb) return 'web';
    final host = Platform.localHostname;
    return host.isEmpty ? 'device' : host;
  } catch (_) {
    return 'device';
  }
}

/// 当前账户名:云端用 [cloudUsername](已由调用方从 /me 获取);
/// 本地模式用当前激活账户的名称(如"张三");都取不到回退 'local'。
Future<String> currentAccountName({
  String? cloudUsername,
  SecureStore? store,
}) async {
  if (cloudUsername != null && cloudUsername.isNotEmpty) return cloudUsername;
  final s = store ?? SecureStore();
  try {
    final activeId = await s.readActiveLocalProfileId();
    if (activeId != null && activeId.isNotEmpty) {
      final profiles = await s.readLocalProfiles();
      for (final p in profiles) {
        if (p['id'] == activeId) {
          final name = p['name']?.toString().trim();
          if (name != null && name.isNotEmpty) return name;
        }
      }
    }
  } catch (_) {
    // 读取失败回退 local。
  }
  return 'local';
}

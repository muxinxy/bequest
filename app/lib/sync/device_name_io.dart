import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

/// io 端设备名:Android/iOS 取设备型号(如 "Pixel 8"/"iPhone 15 Pro"),
/// 桌面取 hostname;失败回退 'device'。
Future<String> platformDeviceName() async {
  try {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      final model = info.model;
      if (model.isNotEmpty) return model;
    } else if (Platform.isIOS || Platform.isMacOS) {
      final info = await DeviceInfoPlugin().iosInfo;
      final name = info.name;
      if (name.isNotEmpty) return name;
    }
    final host = Platform.localHostname;
    return host.isEmpty ? 'device' : host;
  } catch (_) {
    return 'device';
  }
}

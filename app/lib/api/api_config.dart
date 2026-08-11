import 'package:flutter/foundation.dart';

import '../storage/secure_store.dart';
import 'api_client.dart';

/// 服务器地址配置:默认本机后端,可在设置页覆盖(存 secure_store)。
class ApiConfig {
  /// Android 模拟器经 10.0.2.2 访问宿主机;web 与后端同源部署,走相对路径。
  static String get defaultBaseUrl =>
      kIsWeb ? '' : 'http://10.0.2.2:8080';

  static Future<String> baseUrl() async {
    final saved = await SecureStore().readServerUrl();
    if (saved != null && saved.isNotEmpty) return saved;
    // web 同源时用相对路径,免 CORS;设置页仍可覆盖为绝对地址。
    return kIsWeb ? '' : defaultBaseUrl;
  }

  static Future<void> setBaseUrl(String url) => SecureStore().saveServerUrl(url);

  /// 按当前配置构造 API 客户端(设置页可覆盖服务器地址)。
  /// 页面每次创建时调用,保证改完地址立即生效。
  static Future<ApiClient> client() async => ApiClient(baseUrl: await baseUrl());
}

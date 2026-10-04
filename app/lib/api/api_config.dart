import '../storage/secure_store.dart';
import 'api_client.dart';

/// 服务器地址配置:debug 默认本机后端,可在设置页覆盖(存 secure_store)。
class ApiConfig {
  /// Android debug 经 10.0.2.2 访问宿主机;web 与后端同源部署。
  /// profile/release 默认留空,避免预填会被 Android 安全策略拒绝的明文 HTTP 地址。
  static String get defaultBaseUrl => kDefaultBaseUrl;

  static Future<String> baseUrl() async {
    final saved = await SecureStore().readServerUrl();
    if (saved != null && saved.isNotEmpty) return saved;
    // web 同源时用相对路径,免 CORS;设置页仍可覆盖为绝对地址。
    return kDefaultBaseUrl;
  }

  static Future<void> setBaseUrl(String url) => SecureStore().saveServerUrl(url);

  /// 按当前配置构造 API 客户端(设置页可覆盖服务器地址)。
  /// 页面每次创建时调用,保证改完地址立即生效。
  static Future<ApiClient> client() async => ApiClient(baseUrl: await baseUrl());

  /// 校验服务器地址;返回错误提示(中文原文,展示时经 L10n 翻译),
  /// null 表示通过。[httpsOnly] 用于 Android profile/release:系统策略
  /// 禁止明文 HTTP,提前拒绝而不是等网络层失败给通用"连接失败"。
  static String? validateServerUrl(String raw, {required bool httpsOnly}) {
    final text = raw.trim().replaceFirst(RegExp(r'/+$'), '');
    final url = Uri.tryParse(text);
    if (url == null || (url.scheme != 'http' && url.scheme != 'https')) {
      return '地址需以 http:// 或 https:// 开头';
    }
    if (url.host.isEmpty) {
      return '地址缺少主机名';
    }
    if (url.userInfo.isNotEmpty || url.fragment.isNotEmpty) {
      return '地址不应包含用户信息或 # 片段';
    }
    if (httpsOnly && url.scheme != 'https') {
      return 'Android 正式版仅允许 HTTPS 地址';
    }
    return null;
  }
}

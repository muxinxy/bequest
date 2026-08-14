import 'package:http/http.dart' as http;

/// VM/桌面:整个下载(含重定向跟随)。
/// io_client 默认跟随重定向,但 MockClient 不模拟——这里手动处理 302/301,
/// 保证行为一致且可测。桌面无 Referer 防盗链问题;重定向目标保留
/// Authorization 也无碍(OSS 等签名地址忽略多余认证头)。
/// [client] 可注入(测试用 MockClient);默认全局 client。
Future<String> fetchBodyNoReferer(
  Uri uri, {
  Map<String, String>? headers,
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  var response = await c
      .get(uri, headers: headers)
      .timeout(const Duration(seconds: 60));
  var hops = 0;
  while ((response.statusCode == 301 ||
          response.statusCode == 302 ||
          response.statusCode == 307 ||
          response.statusCode == 308) &&
      hops < 5) {
    final location = response.headers['location'];
    if (location == null || location.isEmpty) break;
    hops++;
    response = await c
        .get(Uri.parse(location))
        .timeout(const Duration(seconds: 60));
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw http.ClientException(
      'HTTP ${response.statusCode}',
      uri,
    );
  }
  return response.body;
}

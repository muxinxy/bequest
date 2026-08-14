import 'dart:js_util' as js_util;

/// Web 实现:整个下载(含重定向跟随)用原生 fetch。
/// - referrerPolicy: 'no-referrer' → 不带 Referer,绕过 OSS 等防盗链;
/// - redirect: 'follow'(fetch 默认)→ 自动跟随 302 到签名地址;
/// - 跨域重定向时浏览器自动剥离 Authorization(OSS 签名地址本就无需认证)。
/// [client] 参数仅为与 IO 实现签名一致,web 端不使用。
Future<String> fetchBodyNoReferer(
  Uri uri, {
  Map<String, String>? headers,
  dynamic client,
}) async {
  final init = js_util.jsify({
    'method': 'GET',
    if (headers != null && headers.isNotEmpty) 'headers': headers,
    'referrerPolicy': 'no-referrer',
  });
  final response = await js_util.promiseToFuture(
    js_util.callMethod(js_util.globalThis, 'fetch', [uri.toString(), init]),
  );
  final status = js_util.getProperty(response, 'status') as int;
  if (status < 200 || status >= 300) {
    throw Exception('HTTP $status');
  }
  final text = await js_util.promiseToFuture(
    js_util.callMethod(response, 'text', []),
  );
  return text as String;
}

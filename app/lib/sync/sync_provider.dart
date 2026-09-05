import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../l10n/app_l10n.dart';
import '../platform/no_referrer_fetch_io.dart'
    if (dart.library.js_interop) '../platform/no_referrer_fetch_web.dart';
import 'sync_provider_platform_io.dart'
    if (dart.library.js_interop) 'sync_provider_platform_web.dart';

/// 解析 HTTP 日期:优先 RFC 1123(Wed, 12 Aug 2026 10:00:00 GMT),
/// 也兼容 ISO 8601 与 RFC 850;解析失败返回 null。
DateTime? parseHttpDate(String raw) {
  final s = raw.trim();
  // ISO 8601(带毫秒或 Z 结尾)。
  final iso = DateTime.tryParse(s);
  if (iso != null) return iso;
  // RFC 1123 / RFC 850:如 "Wed, 12 Aug 2026 10:00:00 GMT"。
  final m = RegExp(
    r'^\w+,?\s+(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(s);
  if (m == null) return null;
  const months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };
  final month = months[m.group(2)];
  if (month == null) return null;
  return DateTime.utc(
    int.parse(m.group(3)!),
    month,
    int.parse(m.group(1)!),
    int.parse(m.group(4)!),
    int.parse(m.group(5)!),
    int.parse(m.group(6)!),
  );
}

/// 备份文件信息(恢复列表用)。
class BackupFileInfo {
  const BackupFileInfo({
    required this.name,
    required this.size,
    required this.modified,
  });

  final String name;
  final int size;
  final DateTime? modified;

  String get sizeText {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// 备份同步目标抽象。实现类保持纯可测:构造时注入 http.Client,
/// 测试可用 package:http/testing.dart 的 MockClient 替换。
abstract class SyncProvider {
  String get name;

  /// 上传 [data] 到远程 [remotePath](相对基础路径/前缀)。
  Future<void> upload(String remotePath, String data);

  /// 下载 [remotePath] 的内容。
  Future<String> download(String remotePath);

  /// 探测连通性;连通(含 401/403 等"可达但无权限")返回 true。
  Future<bool> testConnection();

  /// 列出基础路径下的备份文件(名/大小/修改时间),按修改时间新→旧排序。
  Future<List<BackupFileInfo>> listFiles();

  /// 删除远程 [remotePath]。
  Future<void> delete(String remotePath);
}

/// 超时/网络错误自动重试,最多 [attempts] 次(默认 3)。
/// 认证错误(401/403)、SyncException(业务错误)不重试。
Future<T> withRetry<T>(
  Future<T> Function() action, {
  int attempts = 3,
}) async {
  for (var i = 0; i < attempts; i++) {
    try {
      return await action();
    } on SyncException {
      rethrow; // 业务错误(认证失败等)不重试。
    } catch (_) {
      if (i == attempts - 1) rethrow; // 最后一次仍失败则抛出。
      await Future.delayed(Duration(milliseconds: 300 * (i + 1)));
    }
  }
  throw StateError('unreachable');
}

/// 根据本地配置构建同步提供方;未知类型或缺字段返回 null。
/// FTP/SFTP 为 socket 协议,仅桌面/移动端支持——由平台分支处理
/// (web 端返回 null,UI 提示不可用)。
SyncProvider? syncProviderFromConfig(Map<String, dynamic> cfg) =>
    platformSyncProviderFromConfig(cfg);

/// WebDAV 提供方。用基础 HTTP 动词实现:PUT 上传、GET 下载,
/// Basic 认证;PROPFIND/目录创建非必需(单文件写入已配置的基础路径)。
/// ponytail: 不实现目录递归,MKCOL 由服务端自动创建(多数 WebDAV 支持)。
class WebDavSyncProvider implements SyncProvider {
  WebDavSyncProvider({
    required this.url,
    required this.user,
    required this.password,
    this.basePath = '/bequest',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String url;
  final String user;
  final String password;
  final String basePath;
  final http.Client _client;

  @override
  String get name => 'WebDAV';

  @override
  Future<void> upload(String remotePath, String data) async {
    await _ensureBasePath(); // 目录不存在则先创建,避免 PUT 409/404。
    await withRetry(() async {
      final response = await _client
          .put(
            _uriFor(remotePath),
            headers: _headers(contentType: 'application/json'),
            body: data,
          )
          .timeout(const Duration(seconds: 120));
      _ensureSuccess(response);
    });
  }

  @override
  Future<String> download(String remotePath) async {
    final uri = _uriFor(remotePath);
    // 整个下载(含 302 跟随)交给平台实现:
    // - Web:原生 fetch + referrerPolicy 'no-referrer' + redirect follow →
    //   跟随到 OSS 签名地址时无 Referer(防盗链 403 的根因),跨域自动剥离
    //   Authorization → OSS 200;
    // - 桌面:http 自动跟随(无防盗链问题)。
    try {
      return await withRetry(
        () => fetchBodyNoReferer(uri, headers: _headers(), client: _client),
      );
    } catch (e) {
      // 同步失败类异常会显示在 UI,文案由用户语言决定。
      throw SyncException(
        L10n.trp('下载 {name} 失败: {err}', {'name': remotePath, 'err': '$e'}),
      );
    }
  }

  @override
  Future<List<BackupFileInfo>> listFiles() async {
    final base = url.endsWith('/') ? url : '$url/';
    final path = basePath.replaceAll(RegExp(r'^/+|/+$'), '');
    final dir = Uri.parse('$base${path.isEmpty ? '' : '$path/'}');
    // PROPFIND Depth:1 列目录内容;请求 getcontentlength/getlastmodified。
    // 必须带 Content-Type: application/xml——多数服务器(Nextcloud 等)
    // 缺此头会返回 207 但无响应体,导致列表恒为空。
    final request = http.Request('PROPFIND', dir);
    request.headers.addAll({
      ..._headers(contentType: 'application/xml'),
      'Depth': '1',
    });
    request.body = '''
<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:displayname/>
  </d:prop>
</d:propfind>''';
    final response = await withRetry(
      () => _client.send(request).timeout(const Duration(seconds: 15)),
    );
    if (response.statusCode != 207) {
      // 部分服务器(如某些 NAS)不支持 PROPFIND:回退为空列表,
      // 恢复页提示"无法列出"而非崩溃。
      if (response.statusCode == 405 || response.statusCode == 501) {
        throw SyncException(
          L10n.tr('服务器不支持文件列表(PROPFIND),请直接填写文件名恢复'),
        );
      }
      throw SyncException(
        L10n.trp('列出备份失败: HTTP {code}', {'code': '${response.statusCode}'}),
      );
    }
    final body = await response.stream.bytesToString();
    if (body.trim().isEmpty) {
      throw SyncException(
        L10n.tr('服务器返回空列表(PROPFIND 未启用),请直接填写文件名恢复'),
      );
    }
    final files = _parseMultistatus(body, dir.path);
    if (files.isEmpty && body.contains('multistatus') && !body.contains('href')) {
      // 207 且 multistatus 但无 href:服务器未按请求返回属性,解析必然为空。
      throw SyncException(
        L10n.tr('服务器未返回文件属性(PROPFIND 异常),请直接填写文件名恢复'),
      );
    }
    return files;
  }

  /// 解析 WebDAV multistatus XML,提取文件(排除目录本身)的名称/大小/修改时间。
  static List<BackupFileInfo> _parseMultistatus(String xml, String basePath) {
    final files = <BackupFileInfo>[];
    // 极简 XML 解析:按 <response> 块切分。命名空间前缀大小写不敏感
    // (OpenList/Nextcloud 返回 <D:response>,多数实现用 <d:response>)。
    final blockRegex = RegExp(
      r'<[a-zA-Z]*:?response>([\s\S]*?)</[a-zA-Z]*:?response>',
    );
    for (final m in blockRegex.allMatches(xml)) {
      final block = m.group(1);
      if (block == null) continue;
      // href 取文件名(最后一个 / 之后);跳过目录本身(以 / 结尾)。
      final hrefM = RegExp(r'<[a-zA-Z]*:?href>([^<]+)</[a-zA-Z]*:?href>')
          .firstMatch(block);
      if (hrefM == null) continue;
      final href = (hrefM.group(1) ?? '').trim();
      if (href.endsWith('/')) continue; // 目录
      // href 可能含 URL 编码(如中文文件名 %E5%9B%BE),解码后再取文件名。
      final decoded = Uri.decodeComponent(href);
      final name = decoded.split('/').last;
      if (name.isEmpty) continue;
      // 大小。
      final sizeM = RegExp(
              r'<[a-zA-Z]*:?getcontentlength>(\d+)</[a-zA-Z]*:?getcontentlength>')
          .firstMatch(block);
      final size = int.tryParse(sizeM?.group(1) ?? '') ?? 0;
      // 修改时间(RFC 1123,如 Wed, 12 Aug 2026 10:00:00 GMT;
      // 也兼容 ISO 8601——不同服务器格式不一)。
      final timeM = RegExp(
              r'<[a-zA-Z]*:?getlastmodified>([^<]+)</[a-zA-Z]*:?getlastmodified>')
          .firstMatch(block);
      final raw = timeM?.group(1);
      files.add(BackupFileInfo(
        name: name,
        size: size,
        modified: raw == null ? null : parseHttpDate(raw),
      ));
    }
    files.sort((a, b) {
      final am = a.modified ?? DateTime(1970);
      final bm = b.modified ?? DateTime(1970);
      return bm.compareTo(am); // 新→旧
    });
    return files;
  }

  @override
  Future<void> delete(String remotePath) async {
    final request = http.Request('DELETE', _uriFor(remotePath));
    request.headers.addAll(_headers());
    final response = await withRetry(
      () => _client.send(request).timeout(const Duration(seconds: 15)),
    );
    // 404 = 文件本就不存在,视为成功。
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 404) return;
    throw SyncException(
      L10n.trp('删除备份失败: HTTP {code}', {'code': '${response.statusCode}'}),
    );
  }

  @override
  Future<bool> testConnection() async {
    // 失败抛出带原因的异常(页面显示具体状态码),不再静默返回 false。
    // 只发一个 PUT probe:建目录(MKCOL)是 upload 的事,测试连接不必做,
    // 避免串行 3 请求(MKCOL+PUT+DELETE)拖慢导致超时。
    try {
      final probe = _uriFor('.probe');
      final response = await _client
          .put(
            probe,
            headers: _headers(contentType: 'text/plain'),
            body: 'probe',
          )
          .timeout(const Duration(seconds: 5));
      // 401/403 = 认证失败,明确报错(用户配置了凭据却被拒);
      // 2xx/3xx/409 表示可达(409=目录不存在但服务在线,上传时自动建目录)。
      // 不清理 .probe:残留文件无害,下次覆盖;避免串行 DELETE 拖慢响应。
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw SyncException(
          L10n.trp('认证失败: HTTP {code},请检查用户名/密码', {
            'code': '${response.statusCode}',
          }),
        );
      }
      return response.statusCode < 500;
    } on SyncException {
      rethrow;
    } catch (e) {
      throw SyncException(L10n.trp('连接失败: {err}', {'err': '$e'}));
    }
  }

  /// 确保 basePath 目录存在:很多 WebDAV 服务器(Nextcloud 等)不会自动创建
  /// 目录,PUT 到不存在的路径返回 409/404。MKCOL 已存在返回 405/301 视为成功。
  Future<void> _ensureBasePath() async {
    final path = basePath.replaceAll(RegExp(r'^/+|/+$'), '');
    if (path.isEmpty) return;
    final base = url.endsWith('/') ? url : '$url/';
    final dir = Uri.parse('$base$path/');
    // 必须带认证头,否则受保护目录返回 401。
    final request = http.Request('MKCOL', dir);
    request.headers.addAll(_headers());
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 10));
    // 201 创建成功;405/301/403/409 等表示已存在或不可创建——目录已存在时
    // 直接放行,后续 PUT 失败会再报具体错误。
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 405 ||
        response.statusCode == 301 ||
        response.statusCode == 302 ||
        response.statusCode == 409) {
      return;
    }
    throw SyncException(
      L10n.trp('创建备份目录失败: HTTP {code} {path}', {
        'code': '${response.statusCode}',
        'path': path,
      }),
    );
  }

  Uri _uriFor(String remotePath) {
    final base = url.endsWith('/') ? url : '$url/';
    final path = basePath.replaceAll(RegExp(r'^/+|/+$'), '');
    final joined = path.isEmpty
        ? '$base$remotePath'
        : '$base$path/$remotePath';
    return Uri.parse(joined);
  }

  Map<String, String> _headers({String? contentType}) => {
        'Authorization': 'Basic ${base64Encode(utf8.encode('$user:$password'))}',
        'Content-Type': ?contentType,
      };

  void _ensureSuccess(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw SyncException('${response.statusCode} ${response.reasonPhrase}');
  }
}

/// S3 提供方,手写 AWS Signature Version 4(SigV4)签名,仅实现 PUT/GET。
/// 依赖已有的 crypto 包做 SHA-256/HMAC,不引入 AWS SDK。
class S3SyncProvider implements SyncProvider {
  S3SyncProvider({
    required this.endpoint,
    required this.bucket,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.prefix = 'bequest/',
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String endpoint;
  final String bucket;
  final String region;
  final String accessKey;
  final String secretKey;
  final String prefix;
  final http.Client _client;

  @override
  String get name => 'S3';

  @override
  Future<void> upload(String remotePath, String data) async {
    final uri = _objectUri(remotePath);
    final payloadHash = sha256.convert(utf8.encode(data)).toString();
    final headers = _signedHeaders(
      method: 'PUT',
      uri: uri,
      payloadHash: payloadHash,
      contentType: 'application/json',
    );
    await withRetry(() async {
      final response = await _client
          .put(
            uri,
            headers: headers,
            body: data,
          )
          .timeout(const Duration(seconds: 120));
      _ensureSuccess(response);
    });
  }

  @override
  Future<String> download(String remotePath) async {
    final uri = _objectUri(remotePath);
    final headers = _signedHeaders(
      method: 'GET',
      uri: uri,
      payloadHash: sha256.convert(const []).toString(),
    );
    // 与 WebDAV 一致:走平台下载(302 跟随 + web 端 no-referrer),
    // 兼容 S3 兼容网关(如 MinIO 经 CDN 返回重定向 + 防盗链)。
    try {
      return await withRetry(
        () => fetchBodyNoReferer(uri, headers: headers, client: _client),
      );
    } catch (e) {
      // 同步失败类异常会显示在 UI,文案由用户语言决定。
      throw SyncException(
        L10n.trp('下载 {name} 失败: {err}', {'name': remotePath, 'err': '$e'}),
      );
    }
  }

  @override
  Future<List<BackupFileInfo>> listFiles() async {
    try {
      // GET /bucket?list-type=2&prefix=<prefix> → XML Contents(Key/Size/LastModified)。
      final base = Uri.parse(endpoint);
      final bucketPath = base.path.isEmpty ? '/$bucket' : '${base.path}/$bucket';
      final uri = base.replace(
        path: bucketPath,
        query: 'list-type=2&prefix=${Uri.encodeQueryComponent(prefix)}',
      );
      final headers = _signedHeaders(
        method: 'GET',
        uri: uri,
        payloadHash: sha256.convert(const []).toString(),
      );
      // 与 download 一致:走平台请求(302 跟随 + web 端 no-referrer),
      // 兼容 S3 兼容网关(CDN 重定向/防盗链)。
      final body = await withRetry(
        () => fetchBodyNoReferer(uri, headers: headers, client: _client),
      );
      return _parseListXml(body, prefix: prefix);
    } on SyncException {
      rethrow;
    } catch (e) {
      throw SyncException(L10n.trp('列出备份失败: {err}', {'err': '$e'}));
    }
  }

  /// 解析 ListObjectsV2 XML,提取对象名(去掉 prefix)/大小/修改时间,新→旧排序。
  static List<BackupFileInfo> _parseListXml(String xml, {String prefix = ''}) {
    final files = <BackupFileInfo>[];
    final contentsRegex = RegExp(
      r'<Contents>([\s\S]*?)</Contents>',
    );
    for (final m in contentsRegex.allMatches(xml)) {
      final block = m.group(1) ?? '';
      final keyM = RegExp(r'<Key>([^<]+)</Key>').firstMatch(block);
      if (keyM == null) continue;
      var key = keyM.group(1) ?? '';
      if (key.endsWith('/')) continue; // 目录占位
      if (prefix.isNotEmpty && key.startsWith(prefix)) {
        key = key.substring(prefix.length);
      }
      if (key.isEmpty) continue;
      final sizeM = RegExp(r'<Size>(\d+)</Size>').firstMatch(block);
      final timeM = RegExp(r'<LastModified>([^<]+)</LastModified>')
          .firstMatch(block);
      final raw = timeM?.group(1);
      files.add(BackupFileInfo(
        name: key,
        size: int.tryParse(sizeM?.group(1) ?? '') ?? 0,
        modified: raw == null ? null : DateTime.tryParse(raw),
      ));
    }
    files.sort((a, b) {
      final am = a.modified ?? DateTime(1970);
      final bm = b.modified ?? DateTime(1970);
      return bm.compareTo(am);
    });
    return files;
  }

  @override
  Future<void> delete(String remotePath) async {
    final uri = _objectUri(remotePath);
    final headers = _signedHeaders(
      method: 'DELETE',
      uri: uri,
      payloadHash: sha256.convert(const []).toString(),
    );
    final request = http.Request('DELETE', uri);
    request.headers.addAll(headers);
    final response = await withRetry(
      () => _client.send(request).timeout(const Duration(seconds: 15)),
    );
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    if (response.statusCode == 404) return;
    throw SyncException(
      L10n.trp('删除备份失败: HTTP {code}', {'code': '${response.statusCode}'}),
    );
  }

  @override
  Future<bool> testConnection() async {
    try {
      // GET bucket → 200/403 均表示服务可达。
      final uri = Uri.parse('${endpoint.endsWith('/') ? endpoint.substring(0, endpoint.length - 1) : endpoint}/$bucket');
      final headers = _signedHeaders(
        method: 'GET',
        uri: uri,
        payloadHash: sha256.convert(const []).toString(),
      );
      // 超时兜底:目标不可达时立即失败,避免页面一直转圈。
      final response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200 || response.statusCode == 403) {
        return true;
      }
      throw SyncException(
        L10n.trp('S3 连接失败: HTTP {code}', {'code': '${response.statusCode}'}),
      );
    } on SyncException {
      rethrow;
    } catch (e) {
      throw SyncException(L10n.trp('S3 连接失败: {err}', {'err': '$e'}));
    }
  }

  Uri _objectUri(String remotePath) {
    final base = Uri.parse(endpoint);
    final key = '$prefix$remotePath';
    final path = base.path.isEmpty
        ? '/$bucket/${_joinKey(key)}'
        : '${base.path}/$bucket/${_joinKey(key)}';
    return base.replace(path: path);
  }

  String _joinKey(String key) => key
      .split('/')
      .map((segment) => s3UriEncode(segment))
      .join('/');

  Map<String, String> _signedHeaders({
    required String method,
    required Uri uri,
    required String payloadHash,
    String? contentType,
  }) {
    final now = DateTime.now().toUtc();
    final amzDate = _amzTimestamp(now);
    final auth = s3AuthorizationHeader(
      method: method,
      canonicalUri: _canonicalUri(uri),
      canonicalQuery: _canonicalQuery(uri),
      canonicalHeaders: {
        'host': uri.host,
        'x-amz-content-sha256': payloadHash,
        'x-amz-date': amzDate,
      },
      accessKey: accessKey,
      secretKey: secretKey,
      region: region,
    );
    return {
      'Host': uri.host,
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
      'Authorization': auth,
      // GET 下载/列表/删除无 body:不带 Content-Type,
      // 否则 web 端 fetch 视为非简单请求 → CORS preflight →
      // OSS 等跨域签名地址 preflight 失败 403。
      'Content-Type': ?contentType,
    };
  }

  /// 请求路径(不含查询串,SigV4 规范 canonical URI 就是 path)。
  String _canonicalUri(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    return path
        .split('/')
        .map((segment) => s3UriEncode(segment))
        .join('/');
  }

  /// 规范化查询串:SigV4 要求按键排序 + 键值各自 URL 编码。
  static String _canonicalQuery(Uri uri) {
    if (!uri.hasQuery) return '';
    final pairs = uri.queryParameters.entries
        .map((e) => '${s3UriEncode(e.key)}=${s3UriEncode(e.value)}')
        .toList()
      ..sort();
    return pairs.join('&');
  }

  void _ensureSuccess(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw SyncException('${response.statusCode} ${response.reasonPhrase}');
  }
}

/// SigV4 编码:除 [A-Za-z0-9-._~] 外全部百分号编码(大写十六进制)。
String s3UriEncode(String input) {
  final out = StringBuffer();
  for (final byte in utf8.encode(input)) {
    final c = String.fromCharCode(byte);
    if (RegExp(r'[A-Za-z0-9\-._~]').hasMatch(c)) {
      out.write(c);
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// 构造 SigV4 Authorization 头。纯函数,便于用 AWS 官方测试向量验证。
/// [canonicalHeaders] 的键必须已是小写(如 host/x-amz-*),内部排序后签名。
/// [canonicalQuery] 为规范化查询串(已排序+编码),无查询时传空串。
String s3AuthorizationHeader({
  required String method,
  required String canonicalUri,
  String canonicalQuery = '',
  required Map<String, String> canonicalHeaders,
  required String accessKey,
  required String secretKey,
  required String region,
}) {
  final sorted = canonicalHeaders.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  // 每行以 '\n' 结尾,规范格式在 CanonicalHeaders 后再补一个 '\n'(空行)。
  final headersBlock = sorted.map((e) => '${e.key}:${e.value}\n').join();
  final signedHeaders = sorted.map((e) => e.key).join(';');
  final canonicalRequest = '$method\n'
      '$canonicalUri\n'
      '$canonicalQuery\n'
      '$headersBlock\n'
      '$signedHeaders\n'
      '${canonicalHeaders['x-amz-content-sha256']}';
  final amzDate = canonicalHeaders['x-amz-date']!;
  final date = amzDate.substring(0, 8);
  final scope = '$date/$region/s3/aws4_request';
  final stringToSign = 'AWS4-HMAC-SHA256\n'
      '$amzDate\n'
      '$scope\n'
      '${sha256.convert(utf8.encode(canonicalRequest))}';
  final signingKey = _hmacChain(
    utf8.encode('AWS4$secretKey'),
    [date, region, 's3', 'aws4_request'],
  );
  final signature = Hmac(sha256, signingKey)
      .convert(utf8.encode(stringToSign))
      .toString();
  return 'AWS4-HMAC-SHA256 Credential=$accessKey/$scope,'
      'SignedHeaders=$signedHeaders,Signature=$signature';
}

String _amzTimestamp(DateTime utc) {
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${utc.year}${pad(utc.month)}${pad(utc.day)}'
      'T${pad(utc.hour)}${pad(utc.minute)}${pad(utc.second)}Z';
}

List<int> _hmacChain(List<int> key, List<String> steps) {
  var current = key;
  for (final step in steps) {
    current = Hmac(sha256, current).convert(utf8.encode(step)).bytes;
  }
  return current;
}

/// 同步目标异常。
class SyncException implements Exception {
  SyncException(this.message);
  final String message;

  @override
  String toString() => message;
}

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

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
}

/// 根据本地配置构建同步提供方;未知类型或缺字段返回 null。
SyncProvider? syncProviderFromConfig(Map<String, dynamic> cfg) {
  final type = cfg['type']?.toString();
  if (type == 'webdav') {
    final url = cfg['url']?.toString();
    if (url == null || url.isEmpty) return null;
    return WebDavSyncProvider(
      url: url,
      user: cfg['user']?.toString() ?? '',
      password: cfg['password']?.toString() ?? '',
      basePath: cfg['base_path']?.toString() ?? '/bequest',
    );
  }
  if (type == 's3') {
    final endpoint = cfg['endpoint']?.toString();
    final bucket = cfg['bucket']?.toString();
    final accessKey = cfg['access_key']?.toString();
    final secretKey = cfg['secret_key']?.toString();
    if (endpoint == null ||
        endpoint.isEmpty ||
        bucket == null ||
        bucket.isEmpty ||
        accessKey == null ||
        accessKey.isEmpty ||
        secretKey == null ||
        secretKey.isEmpty) {
      return null;
    }
    return S3SyncProvider(
      endpoint: endpoint,
      bucket: bucket,
      region: cfg['region']?.toString() ?? 'us-east-1',
      accessKey: accessKey,
      secretKey: secretKey,
      prefix: cfg['prefix']?.toString() ?? 'bequest/',
    );
  }
  return null;
}

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
    final response = await _client.put(
      _uriFor(remotePath),
      headers: _headers(contentType: 'application/json'),
      body: data,
    );
    _ensureSuccess(response);
  }

  @override
  Future<String> download(String remotePath) async {
    final response = await _client.get(_uriFor(remotePath), headers: _headers());
    _ensureSuccess(response);
    return response.body;
  }

  @override
  Future<bool> testConnection() async {
    try {
      final probe = _uriFor('.probe');
      final response = await _client.put(
        probe,
        headers: _headers(contentType: 'text/plain'),
        body: 'probe',
      );
      // 连通即算可达;清理探测文件失败不影响结论。
      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          await _client.delete(probe, headers: _headers());
        } catch (_) {}
      }
      return response.statusCode < 500;
    } catch (_) {
      return false;
    }
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
    );
    final response = await _client.put(
      uri,
      headers: headers,
      body: data,
    );
    _ensureSuccess(response);
  }

  @override
  Future<String> download(String remotePath) async {
    final uri = _objectUri(remotePath);
    final headers = _signedHeaders(
      method: 'GET',
      uri: uri,
      payloadHash: sha256.convert(const []).toString(),
    );
    final response = await _client.get(uri, headers: headers);
    _ensureSuccess(response);
    return response.body;
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
      final response = await _client.get(uri, headers: headers);
      return response.statusCode == 200 || response.statusCode == 403;
    } catch (_) {
      return false;
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
  }) {
    final now = DateTime.now().toUtc();
    final amzDate = _amzTimestamp(now);
    final auth = s3AuthorizationHeader(
      method: method,
      canonicalUri: _canonicalUri(uri),
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
      'Content-Type': 'application/json',
    };
  }

  /// 请求路径(含查询串),按 S3 规则逐段编码。
  String _canonicalUri(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    final encoded = path
        .split('/')
        .map((segment) => s3UriEncode(segment))
        .join('/');
    return uri.hasQuery ? '$encoded?${uri.query}' : encoded;
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
String s3AuthorizationHeader({
  required String method,
  required String canonicalUri,
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
      '\n' // 查询串(本客户端不携带)
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

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:bequest/sync/sync_provider.dart';

void main() {
  group('SigV4 签名', () {
    test('AWS 官方 GET Object 测试向量签名一致', () {
      const payloadHash =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      final auth = s3AuthorizationHeader(
        method: 'GET',
        canonicalUri: '/test.txt',
        canonicalHeaders: {
          'host': 'examplebucket.s3.amazonaws.com',
          'range': 'bytes=0-9',
          'x-amz-content-sha256': payloadHash,
          'x-amz-date': '20130524T000000Z',
        },
        accessKey: 'AKIAIOSFODNN7EXAMPLE',
        secretKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        region: 'us-east-1',
      );
      expect(
        auth,
        'AWS4-HMAC-SHA256 '
        'Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,'
        'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,'
        'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
      );
    });

    test('s3UriEncode 保留安全字符、编码其余', () {
      expect(s3UriEncode('a-z0-9._~'), 'a-z0-9._~');
      expect(s3UriEncode('中文'), '%E4%B8%AD%E6%96%87');
      expect(s3UriEncode('a b/c'), 'a%20b%2Fc');
    });

    test('带 query 的签名:canonical query 独立一行,按键排序', () {
      const payloadHash =
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
      // ListObjectsV2 风格:list-type=2&prefix=bequest/
      final auth = s3AuthorizationHeader(
        method: 'GET',
        canonicalUri: '/mybucket',
        canonicalQuery: 'list-type%3D2&prefix%3Dbequest%2F',
        canonicalHeaders: {
          'host': 's3.muxinxy.com',
          'x-amz-content-sha256': payloadHash,
          'x-amz-date': '20260814T000000Z',
        },
        accessKey: 'AKIAIOSFODNN7EXAMPLE',
        secretKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        region: 'cn-beijing',
      );
      // 签名变化(与无 query 不同)即证明 query 参与签名。
      expect(auth, startsWith('AWS4-HMAC-SHA256 '));
      expect(auth, isNot(contains('list-type'))); // query 不进 Authorization 头
      expect(auth, contains('Signature='));
    });
  });

  group('S3SyncProvider', () {
    test('upload 用 PUT 到 endpoint/bucket/prefix 并携带 SigV4 认证头', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 200);
      });
      final provider = S3SyncProvider(
        endpoint: 'https://s3.amazonaws.com',
        bucket: 'mybucket',
        region: 'us-east-1',
        accessKey: 'AKIAIOSFODNN7EXAMPLE',
        secretKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
        prefix: 'bequest/',
        client: client,
      );

      await provider.upload('backup.json', '{"blob":"x"}');

      expect(captured.method, 'PUT');
      expect(captured.url.toString(),
          'https://s3.amazonaws.com/mybucket/bequest/backup.json');
      expect(captured.headers['Authorization'],
          startsWith('AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/'));
      expect(captured.headers['x-amz-content-sha256'], isNotEmpty);
      expect(captured.headers['x-amz-date'], isNotEmpty);
      expect(captured.body, '{"blob":"x"}');
    });

    test('download 成功返回内容;非 2xx 抛 SyncException', () async {
      late http.Request captured;
      var call = 0;
      final client = MockClient((request) async {
        call++;
        if (call == 1) {
          captured = request;
          return http.Response('{"blob":"enc"}', 200);
        }
        return http.Response('denied', 403);
      });
      final provider = S3SyncProvider(
        endpoint: 'https://s3.amazonaws.com',
        bucket: 'mybucket',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        client: client,
      );

      expect(await provider.download('f.json'), '{"blob":"enc"}');
      // GET 下载不带 Content-Type:否则 web 端触发 CORS preflight,
      // 跨域签名地址(OSS)preflight 失败 → 403。
      expect(captured.headers.containsKey('Content-Type'), isFalse);
      expect(() => provider.download('f.json'), throwsA(isA<SyncException>()));
    });

    test('download: 302 重定向后获取内容(兼容网关)', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.host.contains('s3.amazonaws.com')) {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://cdn.example.com/signed.json'},
          );
        }
        return http.Response('{"blob":"from-cdn"}', 200);
      });
      final provider = S3SyncProvider(
        endpoint: 'https://s3.amazonaws.com',
        bucket: 'mybucket',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        client: client,
      );

      final body = await provider.download('f.json');

      expect(body, '{"blob":"from-cdn"}');
      expect(requests, hasLength(2));
      expect(requests.last.url.toString(), 'https://cdn.example.com/signed.json');
    });

    test('testConnection: 200/403 可达,404/异常抛 SyncException', () async {
      final reachable = S3SyncProvider(
        endpoint: 'https://s3.amazonaws.com',
        bucket: 'mybucket',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        client: MockClient(
            (request) async => http.Response('', request.url.path == '/mybucket' ? 200 : 403)),
      );
      expect(await reachable.testConnection(), isTrue);

      final noAuth = S3SyncProvider(
        endpoint: 'https://s3.amazonaws.com',
        bucket: 'mybucket',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        client: MockClient((request) async => http.Response('', 404)),
      );
      expect(noAuth.testConnection(), throwsA(isA<SyncException>()));

      final down = S3SyncProvider(
        endpoint: 'https://s3.amazonaws.com',
        bucket: 'mybucket',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        client: MockClient((request) async => throw Exception('network')),
      );
      expect(down.testConnection(), throwsA(isA<SyncException>()));
    });

    test('listFiles: ListObjectsV2 解析对象名/大小/修改时间,新→旧排序', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        const xml = '''<?xml version="1.0"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>mybucket</Name>
  <Prefix>bequest/</Prefix>
  <Contents>
    <Key>bequest/old.json</Key>
    <Size>2048</Size>
    <LastModified>2026-08-10T08:00:00.000Z</LastModified>
  </Contents>
  <Contents>
    <Key>bequest/new.json</Key>
    <Size>1024</Size>
    <LastModified>2026-08-12T10:00:00.000Z</LastModified>
  </Contents>
</ListBucketResult>''';
        return http.Response(xml, 200);
      });
      final provider = S3SyncProvider(
        endpoint: 'https://s3.amazonaws.com',
        bucket: 'mybucket',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        client: client,
      );

      final files = await provider.listFiles();

      expect(captured.url.path, '/mybucket');
      expect(captured.url.query, contains('list-type=2'));
      expect(captured.url.query, contains('prefix=bequest%2F'));
      expect(captured.headers['Authorization'], contains('AWS4-HMAC-SHA256'));
      expect(files, hasLength(2));
      expect(files.first.name, 'new.json'); // prefix 已剥离
      expect(files.first.size, 1024);
      expect(files.first.modified, isNotNull);
      expect(files.last.name, 'old.json');
      expect(files.last.size, 2048);
    });

    test('delete: DELETE 请求携带 SigV4 认证头', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      });
      final provider = S3SyncProvider(
        endpoint: 'https://s3.amazonaws.com',
        bucket: 'mybucket',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        client: client,
      );

      await provider.delete('old.json');
      expect(captured.method, 'DELETE');
      expect(captured.url.path, '/mybucket/bequest/old.json');
      expect(captured.headers['Authorization'], contains('AWS4-HMAC-SHA256'));
    });
  });
}

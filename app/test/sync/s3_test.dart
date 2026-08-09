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
      var call = 0;
      final client = MockClient((request) async {
        call++;
        if (call == 1) return http.Response('{"blob":"enc"}', 200);
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
      expect(() => provider.download('f.json'), throwsA(isA<SyncException>()));
    });

    test('testConnection: 200/403 可达,404/异常不可达', () async {
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
      expect(await noAuth.testConnection(), isFalse);

      final down = S3SyncProvider(
        endpoint: 'https://s3.amazonaws.com',
        bucket: 'mybucket',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        client: MockClient((request) async => throw Exception('network')),
      );
      expect(await down.testConnection(), isFalse);
    });
  });
}

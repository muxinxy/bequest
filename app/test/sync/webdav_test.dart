import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:bequest/sync/sync_provider.dart';

void main() {
  const user = 'alice';
  const password = 'secret';
  final expectedAuth =
      'Basic ${base64Encode(utf8.encode('$user:$password'))}';

  group('WebDavSyncProvider', () {
    test('upload 用 PUT 到 basePath 拼接地址并携带 Basic 认证', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 201);
      });
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        basePath: '/bequest',
        client: client,
      );

      await provider.upload('backup.json', '{"blob":"x"}');

      expect(captured.method, 'PUT');
      expect(captured.url.toString(),
          'https://dav.example.com/bequest/backup.json');
      expect(captured.headers['Authorization'], expectedAuth);
      expect(captured.body, '{"blob":"x"}');
    });

    test('url 结尾无斜杠且 basePath 无前导斜杠也能正确拼接', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      });
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com',
        user: user,
        password: password,
        basePath: 'bequest/',
        client: client,
      );

      await provider.upload('a/b.json', 'data');

      expect(captured.url.toString(), 'https://dav.example.com/bequest/a/b.json');
    });

    test('download 用 GET 并返回内容;非 2xx 抛 SyncException', () async {
      var call = 0;
      final client = MockClient((request) async {
        call++;
        if (call == 1) return http.Response('{"blob":"enc"}', 200);
        return http.Response('oops', 500);
      });
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        client: client,
      );

      expect(await provider.download('f.json'), '{"blob":"enc"}');
      expect(
        () => provider.download('f.json'),
        throwsA(isA<SyncException>()),
      );
    });

    test('testConnection: 2xx/4xx 视为可达,5xx/异常视为失败', () async {
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        client: MockClient((request) async {
          if (request.url.path.endsWith('.probe')) {
            return http.Response('', 201);
          }
          return http.Response('', 200);
        }),
      );
      expect(await provider.testConnection(), isTrue);

      final failing = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        client: MockClient((request) async => http.Response('', 500)),
      );
      expect(await failing.testConnection(), isFalse);

      final unreachable = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        client: MockClient((request) async => throw Exception('network')),
      );
      expect(await unreachable.testConnection(), isFalse);
    });
  });

  group('syncProviderFromConfig', () {
    test('webdav/s3 配置构建对应提供方;缺字段或未知类型返回 null', () {
      expect(
        syncProviderFromConfig({
          'type': 'webdav',
          'url': 'https://dav.example.com/',
        }),
        isA<WebDavSyncProvider>(),
      );
      expect(
        syncProviderFromConfig({
          'type': 's3',
          'endpoint': 'https://s3.amazonaws.com',
          'bucket': 'b',
          'access_key': 'ak',
          'secret_key': 'sk',
          'region': 'us-east-1',
        }),
        isA<S3SyncProvider>(),
      );
      expect(syncProviderFromConfig({'type': 'webdav'}), isNull);
      expect(syncProviderFromConfig({'type': 's3', 'bucket': 'b'}), isNull);
      expect(syncProviderFromConfig({'type': 'ftp'}), isNull);
    });
  });
}

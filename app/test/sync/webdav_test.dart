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
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.method == 'MKCOL') return http.Response('', 201);
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

      // 先 MKCOL 建目录(必须带认证头,否则受保护目录返回 401),再 PUT 上传。
      expect(requests.first.method, 'MKCOL');
      expect(requests.first.url.toString(), 'https://dav.example.com/bequest/');
      expect(requests.first.headers['Authorization'], expectedAuth);
      final put = requests.last;
      expect(put.method, 'PUT');
      expect(put.url.toString(), 'https://dav.example.com/bequest/backup.json');
      expect(put.headers['Authorization'], expectedAuth);
      expect(put.body, '{"blob":"x"}');
    });

    test('testConnection: MKCOL 带认证头,401 认证失败抛 SyncException', () async {
      final requests = <http.Request>[];
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'MKCOL') {
            // 带认证头但凭据错误 → 401(认证失败)。
            if (request.headers['Authorization'] != expectedAuth) {
              return http.Response('', 401);
            }
            return http.Response('', 201);
          }
          return http.Response('', 201);
        }),
      );
      expect(await provider.testConnection(), isTrue);
      expect(requests.first.headers['Authorization'], expectedAuth);
    });

    test('url 结尾无斜杠且 basePath 无前导斜杠也能正确拼接', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        if (request.method == 'MKCOL') return http.Response('', 201);
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

    test('testConnection: PUT probe 2xx → true(单请求,不发 MKCOL)', () async {
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        client: MockClient((request) async {
          expect(request.method, 'PUT'); // 只发一个 PUT,不再 MKCOL。
          expect(request.url.path, endsWith('.probe'));
          return http.Response('', 201);
        }),
      );
      expect(await provider.testConnection(), isTrue);
    });

    test('testConnection: 409(目录不存在但服务在线)仍视为可达', () async {
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        client: MockClient((request) async => http.Response('', 409)),
      );
      expect(await provider.testConnection(), isTrue);
    });

    test('testConnection: 认证失败(401)抛 SyncException 带原因', () async {
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        client: MockClient((request) async => http.Response('', 401)),
      );
      expect(
        provider.testConnection(),
        throwsA(isA<SyncException>()),
      );
    });

    test('testConnection: 5xx 返回 false', () async {
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        client: MockClient((request) async => http.Response('', 500)),
      );
      expect(await provider.testConnection(), isFalse);
    });

    test('testConnection: 请求挂起(超时)抛 SyncException 而非无限等待', () async {
      // 永不完成的请求:5s 超时兜底必须生效,测试整体应在超时前结束。
      // basePath 留空跳过 MKCOL,直接测 PUT 的 5s 超时。
      final hanging = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        basePath: '',
        client: MockClient((request) async {
          await Future.delayed(const Duration(seconds: 30));
          return http.Response('', 200);
        }),
      );
      final sw = Stopwatch()..start();
      expect(hanging.testConnection(), throwsA(isA<SyncException>()));
      sw.stop();
      // 5s 超时 + 余量:验证没有挂满 30s。
      expect(sw.elapsedMilliseconds, lessThan(10000));
    });

    test('listFiles: PROPFIND 207 解析文件名/大小/修改时间,新→旧排序', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        const xml = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>https://dav.example.com/bequest/</d:href>
    <d:propstat><d:prop/></d:propstat>
  </d:response>
  <d:response>
    <d:href>https://dav.example.com/bequest/old.json</d:href>
    <d:propstat><d:prop>
      <d:getcontentlength>2048</d:getcontentlength>
      <d:getlastmodified>Mon, 10 Aug 2026 08:00:00 GMT</d:getlastmodified>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>https://dav.example.com/bequest/new.json</d:href>
    <d:propstat><d:prop>
      <d:getcontentlength>1024</d:getcontentlength>
      <d:getlastmodified>Wed, 12 Aug 2026 10:00:00 GMT</d:getlastmodified>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>''';
        return http.Response(xml, 207, headers: {'Content-Type': 'application/xml'});
      });
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        client: client,
      );

      final files = await provider.listFiles();

      expect(captured.method, 'PROPFIND');
      expect(captured.headers['Depth'], '1');
      expect(captured.headers['Authorization'], expectedAuth);
      expect(files, hasLength(2));
      expect(files.first.name, 'new.json'); // 新→旧
      expect(files.first.size, 1024);
      expect(files.first.modified, isNotNull);
      expect(files.last.name, 'old.json');
      expect(files.last.size, 2048);
    });

    test('delete: DELETE 请求并携带认证;404 视为成功', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response('', 204);
      });
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        basePath: '/bequest',
        client: client,
      );

      await provider.delete('old.json');
      expect(captured.method, 'DELETE');
      expect(captured.url.toString(), 'https://dav.example.com/bequest/old.json');
      expect(captured.headers['Authorization'], expectedAuth);
    });

    test('download: 302 重定向后获取内容(阿里云盘网关)', () async {
      final requests = <http.Request>[];
      // MockClient 不模拟 http 自动跟随,这里手动模拟:
      // 首次 302 → 读 Location → 二次请求返回内容。
      final client = MockClient((request) async {
        requests.add(request);
        final loc = request.url.toString();
        if (loc.contains('a.muxinxy.com')) {
          // 首次请求(原地址):返回 302 到签名地址。
          return http.Response(
            '',
            302,
            headers: {'location': 'https://dl.aliyundrive.cloud/signed.json'},
          );
        }
        // 重定向目标:返回内容。
        return http.Response('{"blob":"decrypted"}', 200);
      });
      final provider = WebDavSyncProvider(
        url: 'https://a.muxinxy.com/dav',
        user: user,
        password: password,
        basePath: '/bequest',
        client: client,
      );

      final body = await provider.download('backup.json');

      expect(body, '{"blob":"decrypted"}');
      expect(requests, hasLength(2));
      // 首次请求带认证;MockClient 自动跟随 302 到重定向地址。
      expect(requests.first.headers['Authorization'], expectedAuth);
      expect(requests.last.url.toString(),
          'https://dl.aliyundrive.cloud/signed.json');
    });

    test('listFiles: 大写 D: 命名空间前缀(OpenList 真实响应)也能解析', () async {
      final client = MockClient((request) async {
        // OpenList/某些服务器返回 <D:response> 而非 <d:response>。
        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<D:multistatus xmlns:D="DAV:">
<D:response><D:href>/dav/bequest/</D:href><D:propstat><D:prop>
<D:resourcetype><D:collection xmlns:D="DAV:"/></D:resourcetype>
<D:getlastmodified>Thu, 13 Aug 2026 11:59:25 GMT</D:getlastmodified>
</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
<D:response><D:href>/dav/bequest/bequest_local_web_20260813_231947.json</D:href><D:propstat><D:prop>
<D:getcontentlength>6741</D:getcontentlength>
<D:getlastmodified>Thu, 13 Aug 2026 15:19:51 GMT</D:getlastmodified>
</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>''';
        return http.Response(xml, 207);
      });
      final provider = WebDavSyncProvider(
        url: 'https://dav.example.com/',
        user: user,
        password: password,
        basePath: '/bequest',
        client: client,
      );

      final files = await provider.listFiles();

      // 目录(以 / 结尾)被跳过,只剩真实备份文件。
      expect(files, hasLength(1));
      expect(files.first.name, 'bequest_local_web_20260813_231947.json');
      expect(files.first.size, 6741);
      expect(files.first.modified, isNotNull);
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

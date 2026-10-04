import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/api/api_client.dart';
import 'package:bequest/api/api_config.dart';

void main() {
  group('ApiClient 服务器地址', () {
    test('非 web 平台空地址:构造即抛 ServerNotConfiguredException', () {
      expect(
        () => ApiClient(baseUrl: ''),
        throwsA(isA<ServerNotConfiguredException>()),
      );
    });

    test('debug 运行模式默认连开发机 17654', () {
      // flutter test 跑在 VM debug 模式:kIsWeb=false、kDebugMode=true。
      expect(ApiClient().baseUrl, 'http://10.0.2.2:17654');
      expect(ApiClient(baseUrl: null).baseUrl, 'http://10.0.2.2:17654');
    });

    test('显式注入地址优先且合法时不抛异常', () {
      final api = ApiClient(baseUrl: 'https://bequest.example.com');
      expect(api.baseUrl, 'https://bequest.example.com');
    });
  });

  group('ApiConfig.validateServerUrl', () {
    test('合法地址返回 null', () {
      expect(
        ApiConfig.validateServerUrl('https://bequest.example.com', httpsOnly: true),
        isNull,
      );
      expect(
        ApiConfig.validateServerUrl('https://bequest.example.com/', httpsOnly: true),
        isNull,
      );
      expect(
        ApiConfig.validateServerUrl('http://10.0.2.2:17654', httpsOnly: false),
        isNull,
      );
    });

    test('scheme 缺失或非 http(s):拒绝', () {
      expect(
        ApiConfig.validateServerUrl('example.com', httpsOnly: false),
        isNotNull,
      );
      expect(
        ApiConfig.validateServerUrl('ftp://backup.example.com', httpsOnly: false),
        isNotNull,
      );
      expect(
        ApiConfig.validateServerUrl('javascript:alert(1)', httpsOnly: false),
        isNotNull,
      );
    });

    test('缺主机名:拒绝', () {
      expect(ApiConfig.validateServerUrl('http://', httpsOnly: false), isNotNull);
      expect(ApiConfig.validateServerUrl('https:///api', httpsOnly: false), isNotNull);
    });

    test('httpsOnly(Android profile/release)拒绝明文 HTTP', () {
      expect(
        ApiConfig.validateServerUrl('http://10.0.2.2:17654', httpsOnly: true),
        isNotNull,
      );
      expect(
        ApiConfig.validateServerUrl('http://192.168.1.10:17654', httpsOnly: true),
        isNotNull,
      );
    });

    test('用户信息与 # 片段:拒绝', () {
      expect(
        ApiConfig.validateServerUrl('https://user:pass@example.com', httpsOnly: false),
        isNotNull,
      );
      expect(
        ApiConfig.validateServerUrl('https://example.com/#frag', httpsOnly: false),
        isNotNull,
      );
    });
  });
}

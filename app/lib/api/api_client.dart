import 'dart:convert';

import 'package:http/http.dart' as http;

/// 后端接口客户端。后端运行在开发机 8080 端口,
/// Android 模拟器通过 http://10.0.2.2:8080 访问。
class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  static const String baseUrl = 'http://10.0.2.2:8080';

  final http.Client _client;

  /// POST /api/v1/auth/register
  Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    required String password,
    required String masterKeyWrapped,
  }) {
    return _post('/api/v1/auth/register', {
      'username': username,
      'email': email,
      'password': password,
      'master_key_wrapped': masterKeyWrapped,
    });
  }

  /// POST /api/v1/auth/login
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) {
    return _post('/api/v1/auth/login', {
      'username': username,
      'password': password,
    });
  }

  /// GET /api/v1/me,携带 JWT。
  Future<Map<String, dynamic>> me(String jwt) {
    return _get('/api/v1/me', jwt);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await _client.post(
      Uri.parse('$baseUrl$path'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> _get(String path, String jwt) async {
    final response = await _client.get(
      Uri.parse('$baseUrl$path'),
      headers: {'Authorization': 'Bearer $jwt'},
    );
    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    final dynamic body = response.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(response.body);
    final map = body is Map<String, dynamic> ? body : const <String, dynamic>{};
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return map;
    }
    final message = map['message'] ?? map['error'] ?? '请求失败(${response.statusCode})';
    throw ApiException(message.toString(), statusCode: response.statusCode);
  }
}

/// 携带后端错误信息的接口异常。
class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

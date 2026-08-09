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

  /// GET /api/v1/categories
  Future<List<Map<String, dynamic>>> listCategories(String jwt) {
    return _getList('/api/v1/categories', jwt);
  }

  /// POST /api/v1/categories
  Future<Map<String, dynamic>> createCategory(String jwt, String name) {
    return _postAuth('/api/v1/categories', {'name': name}, jwt);
  }

  /// DELETE /api/v1/categories/{id}
  Future<void> deleteCategory(String jwt, String id) {
    return _delete('/api/v1/categories/$id', jwt);
  }

  /// GET /api/v1/assets
  Future<List<Map<String, dynamic>>> listAssets(String jwt) {
    return _getList('/api/v1/assets', jwt);
  }

  /// GET /api/v1/assets/{id},包含 encrypted_data。
  Future<Map<String, dynamic>> getAsset(String jwt, String id) {
    return _get('/api/v1/assets/$id', jwt);
  }

  /// POST /api/v1/assets
  Future<Map<String, dynamic>> createAsset(
    String jwt,
    Map<String, dynamic> body,
  ) {
    return _postAuth('/api/v1/assets', body, jwt);
  }

  /// PUT /api/v1/assets/{id}
  Future<Map<String, dynamic>> updateAsset(
    String jwt,
    String id,
    Map<String, dynamic> body,
  ) {
    return _put('/api/v1/assets/$id', body, jwt);
  }

  /// DELETE /api/v1/assets/{id}
  Future<void> deleteAsset(String jwt, String id) {
    return _delete('/api/v1/assets/$id', jwt);
  }

  /// GET /api/v1/inheritors
  Future<List<Map<String, dynamic>>> listInheritors(String jwt) {
    return _getList('/api/v1/inheritors', jwt);
  }

  /// POST /api/v1/inheritors
  Future<Map<String, dynamic>> createInheritor(
    String jwt,
    Map<String, dynamic> body,
  ) {
    return _postAuth('/api/v1/inheritors', body, jwt);
  }

  /// DELETE /api/v1/inheritors/{id}
  Future<void> deleteInheritor(String jwt, String id) {
    return _delete('/api/v1/inheritors/$id', jwt);
  }

  /// GET /api/v1/reminder-templates
  Future<List<Map<String, dynamic>>> listReminderTemplates(String jwt) {
    return _getList('/api/v1/reminder-templates', jwt);
  }

  /// POST /api/v1/reminder-templates
  Future<Map<String, dynamic>> createReminderTemplate(
    String jwt,
    Map<String, dynamic> body,
  ) {
    return _postAuth('/api/v1/reminder-templates', body, jwt);
  }

  /// PUT /api/v1/reminder-templates/{id}
  Future<Map<String, dynamic>> updateReminderTemplate(
    String jwt,
    String id,
    Map<String, dynamic> body,
  ) {
    return _put('/api/v1/reminder-templates/$id', body, jwt);
  }

  /// DELETE /api/v1/reminder-templates/{id}
  Future<void> deleteReminderTemplate(String jwt, String id) {
    return _delete('/api/v1/reminder-templates/$id', jwt);
  }

  /// GET /api/v1/reminders
  Future<List<Map<String, dynamic>>> listReminders(String jwt) {
    return _getList('/api/v1/reminders', jwt);
  }

  /// POST /api/v1/reminders/{id}/read
  Future<Map<String, dynamic>> markReminderRead(String jwt, String id) {
    return _postAuth('/api/v1/reminders/$id/read', const {}, jwt);
  }

  /// GET /api/v1/inheritance/status
  Future<Map<String, dynamic>> getInheritanceStatus(String jwt) {
    return _get('/api/v1/inheritance/status', jwt);
  }

  /// GET /api/v1/audit-log
  Future<List<Map<String, dynamic>>> listAuditLog(String jwt) {
    return _getList('/api/v1/audit-log', jwt);
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

  Future<Map<String, dynamic>> _postAuth(
    String path,
    Map<String, dynamic> body,
    String jwt,
  ) async {
    final response = await _client.post(
      Uri.parse('$baseUrl$path'),
      headers: {'Content-Type': 'application/json', ..._authHeaders(jwt)},
      body: jsonEncode(body),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> _put(
    String path,
    Map<String, dynamic> body,
    String jwt,
  ) async {
    final response = await _client.put(
      Uri.parse('$baseUrl$path'),
      headers: {'Content-Type': 'application/json', ..._authHeaders(jwt)},
      body: jsonEncode(body),
    );
    return _decode(response);
  }

  Future<Map<String, dynamic>> _get(String path, String jwt) async {
    final response = await _client.get(
      Uri.parse('$baseUrl$path'),
      headers: _authHeaders(jwt),
    );
    return _decode(response);
  }

  Future<List<Map<String, dynamic>>> _getList(String path, String jwt) async {
    final response = await _client.get(
      Uri.parse('$baseUrl$path'),
      headers: _authHeaders(jwt),
    );
    _ensureSuccess(response);
    final dynamic decoded = response.body.isEmpty ? const [] : jsonDecode(response.body);
    if (decoded is! List) return const [];
    return decoded.whereType<Map<String, dynamic>>().toList();
  }

  Future<void> _delete(String path, String jwt) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl$path'),
      headers: _authHeaders(jwt),
    );
    _ensureSuccess(response);
  }

  Map<String, String> _authHeaders(String jwt) =>
      {'Authorization': 'Bearer $jwt'};

  void _ensureSuccess(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    dynamic body;
    try {
      body = jsonDecode(response.body);
    } catch (_) {
      body = null;
    }
    final map = body is Map<String, dynamic> ? body : const <String, dynamic>{};
    final message =
        map['message'] ?? map['error'] ?? '请求失败(${response.statusCode})';
    throw ApiException(message.toString(), statusCode: response.statusCode);
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

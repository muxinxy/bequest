import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../logger.dart';

/// 后端接口客户端。后端运行在开发机 8080 端口,
/// Android 模拟器通过 http://10.0.2.2:8080 访问。
class ApiClient {
  /// 默认本机后端;构造时可注入覆盖(见 ApiConfig,设置页可持久化覆盖)。
  ApiClient({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        // ponytail: web 与后端同源,空 baseUrl = 相对路径;移动端默认开发机。
        baseUrl = baseUrl ?? (kIsWeb ? '' : 'http://10.0.2.2:8080');

  final http.Client _client;
  final String baseUrl;

  /// GET /healthz:服务器可用性快速检查(2s 超时由调用方控制)。
  Future<bool> checkServerHealth() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/healthz'),
    ).timeout(const Duration(seconds: 2));
    return response.statusCode == 200;
  }

  /// GET /api/v1/auth/captcha -> {"captcha_id","question"}
  Future<Map<String, dynamic>> getCaptcha() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/v1/auth/captcha'),
    );
    return _decode(response);
  }

  /// POST /api/v1/auth/register
  Future<Map<String, dynamic>> register({
    required String username,
    required String email,
    required String password,
    required String masterKeyWrapped,
    String masterSalt = '',
    String captchaId = '',
    String captcha = '',
  }) {
    return _post('/api/v1/auth/register', {
      'username': username,
      'email': email,
      'password': password,
      'master_key_wrapped': masterKeyWrapped,
      'master_salt': masterSalt,
      'captcha_id': captchaId,
      'captcha': captcha,
    });
  }

  /// POST /api/v1/auth/login
  Future<Map<String, dynamic>> login({
    required String username,
    required String password,
    String captchaId = '',
    String captcha = '',
  }) {
    return _post('/api/v1/auth/login', {
      'username': username,
      'password': password,
      'captcha_id': captchaId,
      'captcha': captcha,
    });
  }

  /// GET /api/v1/auth/check?username=xxx -> {"available":bool}
  Future<Map<String, dynamic>> checkUsername(String username) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/v1/auth/check')
          .replace(queryParameters: {'username': username}),
    );
    return _decode(response);
  }

  /// GET /api/v1/auth/check-email?email=xxx -> {"available":bool}
  Future<Map<String, dynamic>> checkEmail(String email) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/v1/auth/check-email')
          .replace(queryParameters: {'email': email}),
    );
    return _decode(response);
  }

  /// PUT /api/v1/me:改用户名/邮箱
  Future<Map<String, dynamic>> updateProfile(String jwt, Map<String, dynamic> body) {
    return _put('/api/v1/me', body, jwt);
  }

  /// PUT /api/v1/me/password:修改账户密码(改密后旧 token 立即失效)。
  Future<void> changePassword(
    String jwt,
    String password,
    String newPassword,
  ) {
    return _put('/api/v1/me/password', {
      'password': password,
      'new_password': newPassword,
    }, jwt);
  }

  /// POST /api/v1/auth/reset-request:请求重置验证码到邮箱
  Future<Map<String, dynamic>> requestPasswordReset(String email) {
    return _post('/api/v1/auth/reset-request', {'email': email});
  }

  /// POST /api/v1/auth/reset:验证码重置密码
  Future<Map<String, dynamic>> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) {
    return _post('/api/v1/auth/reset', {
      'email': email,
      'code': code,
      'new_password': newPassword,
    });
  }

  /// GET /api/v1/me,携带 JWT。
  Future<Map<String, dynamic>> me(String jwt) {
    return _get('/api/v1/me', jwt);
  }

  /// POST /api/v1/membership/redeem,兑换会员码。
  Future<Map<String, dynamic>> redeemMembership(String jwt, String code) {
    return _postAuth('/api/v1/membership/redeem', {'code': code}, jwt);
  }

  /// GET /api/v1/categories;q 非空时按分组名 LIKE 搜索。
  Future<List<Map<String, dynamic>>> listCategories(String jwt, {String q = ''}) {
    final path = q.isEmpty
        ? '/api/v1/categories'
        : '/api/v1/categories?q=${Uri.encodeQueryComponent(q)}';
    return _getList(path, jwt);
  }

  /// POST /api/v1/categories
  Future<Map<String, dynamic>> createCategory(
    String jwt,
    String name, {
    String assetType = 'physical',
  }) {
    return _postAuth('/api/v1/categories', {'name': name, 'asset_type': assetType}, jwt);
  }

  /// PUT /api/v1/categories/{id}
  Future<Map<String, dynamic>> updateCategory(
    String jwt,
    String id,
    Map<String, dynamic> body,
  ) {
    return _put('/api/v1/categories/$id', body, jwt);
  }

  /// DELETE /api/v1/categories/{id};moveTo 非空时先把资产移入该分组再删。
  Future<void> deleteCategory(String jwt, String id, {int? moveTo}) {
    final q = moveTo == null ? '' : '?move_to=$moveTo';
    return _delete('/api/v1/categories/$id$q', jwt);
  }

  /// PUT /api/v1/categories/order {ids} 自定义分组排序。
  Future<void> reorderCategories(String jwt, List<int> ids) {
    return _put('/api/v1/categories/order', {'ids': ids}, jwt);
  }

  /// POST /api/v1/assets/move 批量移动资产到分组(null = 未分类)。
  Future<Map<String, dynamic>> moveAssets(
    String jwt,
    List<int> ids,
    int? categoryId,
  ) {
    return _postAuth('/api/v1/assets/move', {'ids': ids, 'category_id': categoryId}, jwt);
  }

  /// POST /api/v1/assets/batch-delete 批量软删除(进回收站)。
  Future<Map<String, dynamic>> batchDeleteAssets(String jwt, List<int> ids) {
    return _postAuth('/api/v1/assets/batch-delete', {'ids': ids}, jwt);
  }

  /// POST /api/v1/assets/{id}/copy 复制资产。
  Future<Map<String, dynamic>> copyAsset(String jwt, String id) {
    return _postAuth('/api/v1/assets/$id/copy', {}, jwt);
  }

  /// GET /api/v1/recycle-bin 回收站列表。
  Future<List<Map<String, dynamic>>> listRecycleBin(String jwt) {
    return _getList('/api/v1/recycle-bin', jwt);
  }

  /// POST /api/v1/recycle-bin/{kind}/{id}/restore 恢复。
  Future<Map<String, dynamic>> restoreRecycleItem(String jwt, String kind, String id) {
    return _postAuth('/api/v1/recycle-bin/$kind/$id/restore', {}, jwt);
  }

  /// DELETE /api/v1/recycle-bin/{kind}/{id} 永久删除。
  Future<void> purgeRecycleItem(String jwt, String kind, String id) {
    return _delete('/api/v1/recycle-bin/$kind/$id', jwt);
  }

  /// DELETE /api/v1/recycle-bin 清空回收站。
  Future<void> emptyRecycleBin(String jwt) {
    return _delete('/api/v1/recycle-bin', jwt);
  }

  /// GET /api/v1/categories/{id}/inheritors/{iid}/assets 分组继承预览。
  Future<Map<String, dynamic>> listCategoryInheritorAssets(
    String jwt,
    String categoryId,
    String iid,
  ) {
    return _get('/api/v1/categories/$categoryId/inheritors/$iid/assets', jwt);
  }

  /// GET /api/v1/assets
  Future<List<Map<String, dynamic>>> listAssets(String jwt) {
    return _getList('/api/v1/assets', jwt);
  }

  /// GET /api/v1/assets 分页版:带查询参数返回 {items, total}。
  /// categoryId: 分组 id;0/-1 = 未分组;null = 全部。
  /// q: 按资产名 LIKE 搜索(空串 = 不过滤)。
  /// 兼容旧响应(无参数返回数组)时按数组长度计 total。
  Future<(List<Map<String, dynamic>>, int)> listAssetsPaged(
    String jwt, {
    int? categoryId,
    String q = '',
    int limit = 50,
    int offset = 0,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      if (categoryId != null) 'category_id': '$categoryId',
      if (q.isNotEmpty) 'q': q,
    };
    final response = await _client.get(
      Uri.parse('$baseUrl/api/v1/assets?${Uri(queryParameters: query).query}'),
      headers: _authHeaders(jwt),
    );
    _ensureSuccess(response);
    final dynamic decoded =
        response.body.isEmpty ? null : jsonDecode(response.body);
    if (decoded is List) {
      final items = decoded.whereType<Map<String, dynamic>>().toList();
      return (items, items.length);
    }
    final map =
        decoded is Map<String, dynamic> ? decoded : const <String, dynamic>{};
    final items = (map['items'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final total = (map['total'] as num?)?.toInt() ?? items.length;
    return (items, total);
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

  /// GET /api/v1/assets/{id}/inheritors:该资产的继承人绑定列表
  Future<List<Map<String, dynamic>>> listAssetInheritors(
    String jwt,
    String assetId,
  ) {
    return _getList('/api/v1/assets/$assetId/inheritors', jwt);
  }

  /// POST /api/v1/assets/{id}/inheritors:绑定继承人到资产
  Future<Map<String, dynamic>> createAssetInheritor(
    String jwt,
    String assetId,
    Map<String, dynamic> body,
  ) {
    return _postAuth('/api/v1/assets/$assetId/inheritors', body, jwt);
  }

  /// DELETE /api/v1/assets/{id}/inheritors/{iid}
  Future<void> deleteAssetInheritor(String jwt, String assetId, String iid) {
    return _delete('/api/v1/assets/$assetId/inheritors/$iid', jwt);
  }

  /// GET /api/v1/categories/{id}/inheritors:该分组的继承人绑定列表
  Future<List<Map<String, dynamic>>> listCategoryInheritors(
    String jwt,
    String categoryId,
  ) {
    return _getList('/api/v1/categories/$categoryId/inheritors', jwt);
  }

  /// POST /api/v1/categories/{id}/inheritors:绑定继承人到分组
  Future<Map<String, dynamic>> createCategoryInheritor(
    String jwt,
    String categoryId,
    Map<String, dynamic> body,
  ) {
    return _postAuth('/api/v1/categories/$categoryId/inheritors', body, jwt);
  }

  /// DELETE /api/v1/categories/{id}/inheritors/{iid}
  Future<void> deleteCategoryInheritor(String jwt, String categoryId, String iid) {
    return _delete('/api/v1/categories/$categoryId/inheritors/$iid', jwt);
  }

  /// GET /api/v1/inheritors/{id}/assets:该继承人绑定的所有资产(含分组继承)
  Future<List<Map<String, dynamic>>> listInheritorAssets(
    String jwt,
    String inheritorId,
  ) {
    return _getList('/api/v1/inheritors/$inheritorId/assets', jwt);
  }

  /// GET /api/v1/inheritors
  Future<List<Map<String, dynamic>>> listInheritors(String jwt) {
    return _getList('/api/v1/inheritors', jwt);
  }

  /// PUT /api/v1/inheritors/{id}:改名称/邮箱/访问码(access_code 留空则不改)。
  Future<Map<String, dynamic>> updateInheritor(
    String jwt,
    String id,
    Map<String, dynamic> body,
  ) {
    return _put('/api/v1/inheritors/$id', body, jwt);
  }

  /// GET /api/v1/trigger-ladders:触发阶梯列表(含全局,is_global=1)。
  Future<List<Map<String, dynamic>>> listTriggerLadders(String jwt) {
    return _getList('/api/v1/trigger-ladders', jwt);
  }

  /// POST /api/v1/trigger-ladders {name, days} -> 201
  Future<Map<String, dynamic>> createTriggerLadder(
    String jwt, {
    required String name,
    required List<int> days,
  }) {
    return _postAuth(
      '/api/v1/trigger-ladders',
      {'name': name, 'days': days},
      jwt,
    );
  }

  /// PUT /api/v1/trigger-ladders/{id} {name, days} -> 200(全局也可改)。
  Future<Map<String, dynamic>> updateTriggerLadder(
    String jwt,
    String id, {
    required String name,
    required List<int> days,
  }) {
    return _put('/api/v1/trigger-ladders/$id', {'name': name, 'days': days}, jwt);
  }

  /// DELETE /api/v1/trigger-ladders {ids} -> {"deleted":n,"skipped":m}
  /// 全局阶梯不可删;删除后引用它的继承自动回退全局。
  Future<Map<String, dynamic>> deleteTriggerLadders(
    String jwt,
    List<int> ids,
  ) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl/api/v1/trigger-ladders'),
      headers: {'Content-Type': 'application/json', ..._authHeaders(jwt)},
      body: jsonEncode({'ids': ids}),
    );
    return _decode(response);
  }

  /// GET /api/v1/trigger-ladders/{id}/bindings:该阶梯绑定的资产/分组及继承人。
  /// 全局阶梯返回所有 ladder_id IS NULL 的绑定;自定义返回 ladder_id=该 id。
  Future<Map<String, dynamic>> getLadderBindings(String jwt, int id) {
    return _get('/api/v1/trigger-ladders/$id/bindings', jwt);
  }

  /// POST /api/v1/trigger-ladders/unbind {ladder_id, asset_bindings, category_bindings}
  /// 按绑定行粒度解绑(binding_id 列表);解绑后对应资产/分组回退全局阶梯。
  Future<Map<String, dynamic>> unbindLadder(
    String jwt, {
    required int ladderId,
    required List<int> assetBindings,
    required List<int> categoryBindings,
  }) {
    return _postAuth(
      '/api/v1/trigger-ladders/unbind',
      {
        'ladder_id': ladderId,
        'asset_bindings': assetBindings,
        'category_bindings': categoryBindings,
      },
      jwt,
    );
  }

  /// PUT /api/v1/assets/{id}/inheritors/{iid} {ladder_id}:修改绑定阶梯(null=全局)。
  Future<Map<String, dynamic>> updateAssetInheritorLadder(
    String jwt,
    String assetId,
    String iid,
    int? ladderId,
  ) {
    return _put(
      '/api/v1/assets/$assetId/inheritors/$iid',
      {'ladder_id': ladderId},
      jwt,
    );
  }

  /// PUT /api/v1/categories/{id}/inheritors/{iid} {ladder_id}:修改绑定阶梯(null=全局)。
  Future<Map<String, dynamic>> updateCategoryInheritorLadder(
    String jwt,
    String categoryId,
    String iid,
    int? ladderId,
  ) {
    return _put(
      '/api/v1/categories/$categoryId/inheritors/$iid',
      {'ladder_id': ladderId},
      jwt,
    );
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

  /// POST /api/v1/reminders/read-all
  Future<Map<String, dynamic>> markAllRemindersRead(String jwt) {
    return _postAuth('/api/v1/reminders/read-all', const {}, jwt);
  }

  /// GET /api/v1/inheritance/status
  Future<Map<String, dynamic>> getInheritanceStatus(String jwt) {
    return _get('/api/v1/inheritance/status', jwt);
  }

  /// GET /api/v1/inheritance/events?month=&q=&limit=&offset= -> {items, total}
  /// month 形如 '2026-08';q 搜资产名/继承人名;limit 默认 50,最大 200。
  Future<(List<Map<String, dynamic>>, int)> getInheritanceEvents(
    String jwt, {
    String month = '',
    String q = '',
    int limit = 50,
    int offset = 0,
  }) async {
    final query = <String, String>{
      'limit': '$limit',
      'offset': '$offset',
      if (month.isNotEmpty) 'month': month,
      if (q.isNotEmpty) 'q': q,
    };
    final response = await _client.get(
      Uri.parse(
        '$baseUrl/api/v1/inheritance/events?${Uri(queryParameters: query).query}',
      ),
      headers: _authHeaders(jwt),
    );
    _ensureSuccess(response);
    final dynamic decoded =
        response.body.isEmpty ? null : jsonDecode(response.body);
    final map =
        decoded is Map<String, dynamic> ? decoded : const <String, dynamic>{};
    final items = (map['items'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final total = (map['total'] as num?)?.toInt() ?? items.length;
    return (items, total);
  }

  /// GET /api/v1/inheritance/events/export?month=&q= -> CSV 文本(浏览器下载/分享用)。
  Future<String> exportInheritanceEvents(
    String jwt, {
    String month = '',
    String q = '',
  }) async {
    final query = <String, String>{
      if (month.isNotEmpty) 'month': month,
      if (q.isNotEmpty) 'q': q,
    };
    final response = await _client.get(
      Uri.parse(
        '$baseUrl/api/v1/inheritance/events/export?${Uri(queryParameters: query).query}',
      ),
      headers: _authHeaders(jwt),
    );
    _ensureSuccess(response);
    return response.body;
  }

  /// GET /api/v1/inheritance/preview:继承触发预览(阶梯/交接资产/继承人/说明)。
  Future<Map<String, dynamic>> getInheritancePreview(String jwt) {
    return _get('/api/v1/inheritance/preview', jwt);
  }

  /// GET /api/v1/inheritance/default-inheritor:默认继承人(inheritor_id 可为 null)。
  Future<Map<String, dynamic>> getDefaultInheritor(String jwt) {
    return _get('/api/v1/inheritance/default-inheritor', jwt);
  }

  /// PUT /api/v1/inheritance/default-inheritor {inheritor_id: int?}:设置默认继承人(null=按第一顺位)。
  Future<Map<String, dynamic>> putDefaultInheritor(String jwt, int? inheritorId) {
    return _put(
      '/api/v1/inheritance/default-inheritor',
      {'inheritor_id': inheritorId},
      jwt,
    );
  }

  /// GET /api/v1/notification-usage:本月通知用量(邮件/短信已用与额度)。
  Future<Map<String, dynamic>> getNotificationUsage(String jwt) {
    return _get('/api/v1/notification-usage', jwt);
  }

  /// GET /api/v1/audit-log
  Future<List<Map<String, dynamic>>> listAuditLog(String jwt) {
    return _getList('/api/v1/audit-log', jwt);
  }

  /// GET /api/v1/logs?kind=&month=&limit=500 -> 日志列表(倒序)。
  /// kind: '' = 全部, 'audit' = 审计, 'app' = 应用;month 形如 '2026-08'。
  Future<List<Map<String, dynamic>>> listLogs(
    String jwt, {
    String kind = '',
    String month = '',
    int limit = 500,
  }) {
    final q = <String, String>{
      if (kind.isNotEmpty) 'kind': kind,
      if (month.isNotEmpty) 'month': month,
      'limit': '$limit',
    };
    return _getList('/api/v1/logs?${Uri(queryParameters: q).query}', jwt);
  }

  /// GET /api/v1/logs/months -> 有日志的月份列表,如 ["2026-08", ...]。
  Future<List<String>> listLogMonths(String jwt) async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/v1/logs/months'),
      headers: _authHeaders(jwt),
    );
    _ensureSuccess(response);
    final dynamic decoded = response.body.isEmpty ? const [] : jsonDecode(response.body);
    if (decoded is! List) return const [];
    return decoded.whereType<String>().toList();
  }

  /// GET /api/v1/logs/export?kind=&month= -> CSV 文本(浏览器下载/分享用)。
  Future<String> exportLogs(
    String jwt, {
    String kind = '',
    String month = '',
  }) async {
    final q = <String, String>{
      if (kind.isNotEmpty) 'kind': kind,
      if (month.isNotEmpty) 'month': month,
    };
    final response = await _client.get(
      Uri.parse('$baseUrl/api/v1/logs/export?${Uri(queryParameters: q).query}'),
      headers: _authHeaders(jwt),
    );
    _ensureSuccess(response);
    return response.body;
  }

  /// DELETE /api/v1/logs?kind=&month= -> {"deleted":n} 清除日志。
  Future<Map<String, dynamic>> clearLogs(
    String jwt, {
    String kind = '',
    String month = '',
  }) async {
    final q = <String, String>{
      if (kind.isNotEmpty) 'kind': kind,
      if (month.isNotEmpty) 'month': month,
    };
    final response = await _client.delete(
      Uri.parse('$baseUrl/api/v1/logs?${Uri(queryParameters: q).query}'),
      headers: _authHeaders(jwt),
    );
    return _decode(response);
  }

  /// GET /api/v1/notification-channels -> {"emails":[],"phones":[],"wecom":[],"dingtalk":[],"feishu":[]}(各 0-3 个)。
  Future<Map<String, dynamic>> getNotificationChannels(String jwt) {
    return _get('/api/v1/notification-channels', jwt);
  }

  /// PUT /api/v1/notification-channels {emails,phones,wecom,dingtalk,feishu}:整体替换。
  /// 免费用户提交手机号 -> 400「手机号功能为会员专属」;IM webhook 不限 tier。
  Future<Map<String, dynamic>> putNotificationChannels(
    String jwt, {
    required List<String> emails,
    required List<String> phones,
    List<String> wecom = const [],
    List<String> dingtalk = const [],
    List<String> feishu = const [],
  }) {
    return _put(
      '/api/v1/notification-channels',
      {
        'emails': emails,
        'phones': phones,
        'wecom': wecom,
        'dingtalk': dingtalk,
        'feishu': feishu,
      },
      jwt,
    );
  }

  /// GET /api/v1/settings/smtp(不含密码,configured=false 表示未配置)。
  Future<Map<String, dynamic>> getSmtpSettings(String jwt) {
    return _get('/api/v1/settings/smtp', jwt);
  }

  /// PUT /api/v1/settings/smtp
  Future<Map<String, dynamic>> updateSmtpSettings(
    String jwt,
    Map<String, dynamic> body,
  ) {
    return _put('/api/v1/settings/smtp', body, jwt);
  }

  /// DELETE /api/v1/settings/smtp → {"configured":false}
  Future<Map<String, dynamic>> deleteSmtpSettings(String jwt) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl/api/v1/settings/smtp'),
      headers: _authHeaders(jwt),
    );
    return _decode(response);
  }

  /// GET /api/v1/settings/inheritance → {"enabled":bool}
  Future<Map<String, dynamic>> getInheritanceToggle(String jwt) =>
      _get('/api/v1/settings/inheritance', jwt);

  /// PUT /api/v1/settings/inheritance {"enabled":bool} → {"enabled":bool}
  Future<Map<String, dynamic>> putInheritanceToggle(
    String jwt,
    bool enabled,
  ) {
    return _put('/api/v1/settings/inheritance', {'enabled': enabled}, jwt);
  }

  /// PUT /api/v1/settings/master-key,修改主密码后更新云端继承密钥包装。
  /// [accountPassword] 为账户登录密码(服务端校验);401 = 账户密码错误。
  Future<Map<String, dynamic>> updateMasterKeyWrapped(
    String jwt,
    String accountPassword,
    String wrappedB64,
  ) {
    return _put('/api/v1/settings/master-key', {
      'password': accountPassword,
      'master_key_wrapped': wrappedB64,
    }, jwt);
  }

  /// PUT /api/v1/settings/master-salt(老账号回填:注册前无盐上传,
  /// 本机有盐而服务端缺 → 登录时回填,供其他设备跨设备恢复)。
  Future<void> updateMasterSalt(String jwt, String salt) {
    return _put('/api/v1/settings/master-salt', {'master_salt': salt}, jwt);
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
    Logger.instance.e(
      'api ${response.request?.url.path ?? ''} error '
      '${response.statusCode}: $message',
    );
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
    Logger.instance.e(
      'api ${response.request?.url.path ?? ''} error '
      '${response.statusCode}: $message',
    );
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

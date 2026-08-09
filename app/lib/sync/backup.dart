import 'dart:convert';

import '../api/api_client.dart';
import '../crypto/asset_crypto.dart';
import '../crypto/key_derivation.dart';
import '../models/preset_categories.dart';
import '../storage/secure_store.dart';
import 'local_vault.dart';

final Set<String> _presetCategoryNames = {
  ...kPhysicalPresetCategories,
  ...kVirtualPresetCategories,
};

/// 校验备份 JSON。非法(非备份/版本不符/缺 assets)返回 null。
Map<String, dynamic>? parseBackupJson(String text) {
  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return null;
  }
  if (decoded is! Map<String, dynamic>) return null;
  if (decoded['app'] != 'bequest' || decoded['type'] != 'backup') return null;
  if (decoded['version'] != 1) return null;
  if (decoded['assets'] is! List) return null;
  return decoded;
}

/// 拉取服务器全部数据(资产含 encrypted_data,分类/模板/继承人原样),构建备份 JSON。
/// 单条资产详情拉取失败时跳过,不阻断整体备份。
Future<String> _fetchAll(String jwt, ApiClient api) async {
  final assets = await api.listAssets(jwt);
  final fullAssets = <Map<String, dynamic>>[];
  for (final asset in assets) {
    try {
      fullAssets.add(await api.getAsset(jwt, '${asset['id']}'));
    } catch (_) {
      // 已删除或无权访问的资产:跳过。
    }
  }
  return jsonEncode({
    'app': 'bequest',
    'type': 'backup',
    'version': 1,
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    'assets': fullAssets,
    'categories': await api.listCategories(jwt),
    'reminder_templates': await api.listReminderTemplates(jwt),
    'inheritors': await api.listInheritors(jwt),
  });
}

/// 构建备份 JSON:优先读取本地加密快照(无需登录);
/// 无快照且已登录则从服务器拉取并写入本地快照后返回;
/// 两者皆无则抛 StateError。
Future<String> buildBackupJson(
  String? jwt,
  ApiClient api,
  String masterKeyB64, {
  LocalVault? vault,
}) async {
  final local = vault ?? LocalVault();
  final cached = await local.loadVault(masterKeyB64);
  if (cached != null) return cached;
  if (jwt == null) throw StateError('无本地数据且未登录');
  final backup = await _fetchAll(jwt, api);
  try {
    await local.saveVault(backup, masterKeyB64);
  } catch (_) {
    // 本地快照缓存失败不影响本次同步。
  }
  return backup;
}

/// 强制刷新本地加密快照:从服务器拉取全量数据并覆盖保存。
/// 登录成功后调用,保证本地快照与云端一致。
Future<void> refreshLocalVault(
  String jwt,
  ApiClient api,
  String masterKeyB64, {
  LocalVault? vault,
}) async {
  final backup = await _fetchAll(jwt, api);
  await (vault ?? LocalVault()).saveVault(backup, masterKeyB64);
}

/// 将备份写入本地加密快照(未登录时恢复的落点)。
Future<void> restoreToLocal(
  String backupJson,
  String masterKeyB64, {
  LocalVault? vault,
}) async {
  await (vault ?? LocalVault()).saveVault(backupJson, masterKeyB64);
}

/// 将备份 JSON 用主密钥加密为上传负载。
/// 上传文件内容即此负载 JSON:{"blob": base64(nonce||ct||tag), "salt"?, "created_at": ISO}。
/// [salt] 为派生主密钥用的盐(base64),随负载上传以便跨设备用主密码恢复。
Future<Map<String, dynamic>> buildSyncPayload(
  String backupJson,
  String masterKeyB64, {
  String? salt,
}) async {
  return {
    'blob': encryptSensitiveData(backupJson, masterKeyB64),
    if (salt != null && salt.isNotEmpty) 'salt': salt,
    'created_at': DateTime.now().toUtc().toIso8601String(),
  };
}

/// 同步负载中的盐(base64);无则返回 null。
String? payloadSalt(String payloadJson) {
  try {
    final decoded = jsonDecode(payloadJson);
    if (decoded is Map<String, dynamic>) {
      final salt = decoded['salt']?.toString();
      if (salt != null && salt.isNotEmpty) return salt;
    }
  } catch (_) {
    // 非 JSON / 缺字段:无盐。
  }
  return null;
}

/// 解密上传负载:优先用本机已存主密钥;失败且提供主密码时,
/// 用负载内 salt 派生密钥再试。全部失败返回 null。
Future<String?> extractBackupJsonAny(
  String payloadJson, {
  String? password,
  SecureStore? store,
}) async {
  final s = store ?? SecureStore();
  final mk = await s.readMasterKey();
  if (mk != null && mk.isNotEmpty) {
    final result = await extractBackupJson(payloadJson, mk);
    if (result != null) return result;
  }
  final salt = payloadSalt(payloadJson);
  if (password != null && password.isNotEmpty && salt != null) {
    final result =
        await extractBackupJson(payloadJson, deriveMasterKey(password, salt));
    if (result != null) return result;
  }
  return null;
}

/// 解密上传负载,取回备份 JSON;密钥错误/数据被篡改返回 null。
Future<String?> extractBackupJson(
  String payloadJson,
  String masterKeyB64,
) async {
  try {
    final decoded = jsonDecode(payloadJson);
    if (decoded is! Map<String, dynamic>) return null;
    final blob = decoded['blob']?.toString();
    if (blob == null || blob.isEmpty) return null;
    return decryptSensitiveData(blob, masterKeyB64);
  } catch (_) {
    return null;
  }
}

/// 从备份恢复资产:MVP 仅恢复资产,分类按名重建,模板/继承人另行处理。
/// 返回 (成功数, 失败数)。
/// ponytail: 不恢复模板/继承人;备份中已含全量数据,需要时补两条循环即可。
Future<({int ok, int fail})> restoreAssets(
  String backupJson,
  String jwt,
  ApiClient api,
) async {
  final backup = parseBackupJson(backupJson);
  if (backup == null) return (ok: 0, fail: 0);
  final assets = (backup['assets'] as List)
      .whereType<Map<String, dynamic>>()
      .toList();
  // 备份内分类 id → 名字(服务端 id 每次部署不同,只能按名对应)。
  final backupCatNames = <String, String>{
    for (final c
        in (backup['categories'] as List).whereType<Map<String, dynamic>>())
      if (c['id'] != null && c['name'] != null) '${c['id']}': '${c['name']}',
  };
  final serverCatIdByName = <String, String>{
    for (final c in await api.listCategories(jwt))
      if (c['id'] != null && c['name'] != null) '${c['name']}': '${c['id']}',
  };
  var ok = 0;
  var fail = 0;
  for (final asset in assets) {
    try {
      final categoryId = await _resolveCategoryId(
        asset['category_id']?.toString(),
        backupCatNames,
        serverCatIdByName,
        jwt,
        api,
      );
      await api.createAsset(jwt, {
        'name': asset['name']?.toString() ?? '',
        'asset_type': asset['asset_type']?.toString() ?? 'physical',
        'encrypted_data': asset['encrypted_data']?.toString() ?? '',
        'expiry_date': asset['expiry_date']?.toString(),
        'category_id': ?categoryId,
      });
      ok++;
    } catch (_) {
      fail++;
    }
  }
  return (ok: ok, fail: fail);
}

/// 按备份的分类名解析目标分类 id:预设名/未知 → null(未分类);
/// 自定义分类已存在 → 复用;否则创建并缓存。
Future<String?> _resolveCategoryId(
  String? categoryId,
  Map<String, String> backupCatNames,
  Map<String, String> serverCatIdByName,
  String jwt,
  ApiClient api,
) async {
  if (categoryId == null || categoryId.isEmpty) return null;
  final name = backupCatNames[categoryId];
  if (name == null || name.isEmpty || _presetCategoryNames.contains(name)) {
    return null;
  }
  final existing = serverCatIdByName[name];
  if (existing != null) return existing;
  final created = await api.createCategory(jwt, name);
  final id = '${created['id']}';
  serverCatIdByName[name] = id;
  return id;
}

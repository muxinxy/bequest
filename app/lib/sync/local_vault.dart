import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;

import '../crypto/asset_crypto.dart';
import '../platform/string_store.dart';
import '../platform/string_store_io.dart'
    if (dart.library.js_interop) '../platform/string_store_web.dart';
import '../storage/secure_store.dart';

/// 本地加密快照:单文件存储加密 JSON(AES-256-GCM)。VM 落文件,Web 落 localStorage。
///
/// 文件按当前本地账户隔离:旧账户(legacy)沿用 vault.bq(零迁移),
/// 新建账户用 vault_<账户id>.bq;云端备份(无当前账户)用 vault.bq。
///
/// 同一存储两种用途(互斥覆盖):
/// - 备份串(backup.dart 的 loadVault/saveVault):最近一次全量备份 JSON;
/// - 本地库对象(saveLocalData/loadLocalData):{"schema":1,"salt":...,"assets":[...],"categories":[...]}。
class LocalVault {
  LocalVault({this.directory});

  /// 离线缓存大小上限(字节,密文计)。超过则拒绝写入——
  /// 防止离线缓存无限膨胀,仅保留"可离线查看/导出"所需。
  /// 移动端 50 MB(存储充足,离线场景多);Web 5 MB(localStorage 上限)。
  static int get maxCacheBytes => kIsWeb
      ? 5 * 1024 * 1024   // Web: 5 MB (浏览器 localStorage 通常 5-10 MB)
      : 50 * 1024 * 1024; // 移动端/桌面: 50 MB

  /// 测试可注入临时目录;默认使用应用文档目录。
  final String? directory;

  StringStore? _cached;

  Future<StringStore> _store() async {
    if (_cached != null) return _cached!;
    var name = 'vault.bq';
    try {
      final active = await SecureStore().readActiveLocalProfileId();
      if (active != null && active.isNotEmpty && active != 'legacy') {
        name = 'vault_$active.bq';
      }
    } catch (_) {
      // 测试环境无 secure storage 平台:回退默认文件。
    }
    _cached = makeStringStore(
      fileName: name,
      directoryProvider: directory == null ? null : () async => directory!,
    );
    return _cached!;
  }

  /// 加密快照;超限返回 null(不写入)。
  /// 先按明文长度预判(base64 密文 ≈ 明文 × 4/3 + 开销,明文超限必超限),
  /// 避免对大缓存做无谓加密。
  Future<String?> _encryptBounded(String plain, String masterKeyB64) async {
    if (plain.length > maxCacheBytes) return null;
    final blob = encryptSensitiveData(plain, masterKeyB64);
    if (blob.length > maxCacheBytes) return null;
    return blob;
  }

  /// 读取并解密快照原文;存储缺失/密钥错误/数据被篡改均返回 null。
  Future<String?> _readDecrypted(String masterKeyB64) async {
    try {
      final raw = await (await _store()).read();
      if (raw == null) return null;
      return decryptSensitiveData(raw, masterKeyB64);
    } catch (_) {
      return null;
    }
  }

  /// 读取解密后的快照原文(备份串)。存储缺失/密钥错误返回 null。
  Future<String?> loadVault(String masterKeyB64) => _readDecrypted(masterKeyB64);

  /// 加密并写入快照。注意:会覆盖本地库对象,两者互斥。
  /// 超限时不写入(静默跳过,离线缓存有界)。
  Future<void> saveVault(String backupJson, String masterKeyB64) async {
    final blob = await _encryptBounded(backupJson, masterKeyB64);
    if (blob == null) return;
    await (await _store()).write(blob);
  }

  /// 读取本地库对象(解密 + JSON 解码)。无存储/密钥错误 → null。
  /// 旧版纯备份串(无 schema 字段)按空库返回,不崩溃。
  Future<Map<String, dynamic>?> loadLocalData(String masterKeyB64) async {
    final raw = await _readDecrypted(masterKeyB64);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['schema'] != 1) {
        // 旧版备份串:无本地库对象结构,按空库处理。
        return {
          'schema': 1,
          'assets': <Map<String, dynamic>>[],
          'categories': <Map<String, dynamic>>[],
        };
      }
      return decoded;
    } catch (_) {
      return null;
    }
  }

  /// 将本地库对象编码、加密并写入。可选 [salt] 供跨设备恢复主密钥派生。
  /// 超限时不写入(静默跳过,离线缓存有界)。
  Future<void> saveLocalData(
    Map<String, dynamic> data,
    String masterKeyB64, {
    String? salt,
  }) async {
    if (salt != null) data['salt'] = salt;
    final blob = await _encryptBounded(jsonEncode(data), masterKeyB64);
    if (blob == null) return;
    await (await _store()).write(blob);
  }

  /// 从本地库对象读取 salt(跨设备恢复用);旧版备份串/无 salt → null。
  Future<String?> readSalt(String masterKeyB64) async {
    final data = await loadLocalData(masterKeyB64);
    return data?['salt']?.toString();
  }

  /// 删除本地快照(存在才删)。
  Future<void> clearVault() async => (await _store()).delete();
}

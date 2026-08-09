import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../crypto/asset_crypto.dart';

/// 本地加密快照:单文件存储加密 JSON(AES-256-GCM)。
///
/// 同一文件两种用途(互斥覆盖):
/// - 备份串(backup.dart 的 loadVault/saveVault):最近一次全量备份 JSON;
/// - 本地库对象(saveLocalData/loadLocalData):{"schema":1,"salt":...,"assets":[...],"categories":[...]}。
class LocalVault {
  LocalVault({this.directory});

  /// 测试可注入临时目录;默认使用应用文档目录。
  final String? directory;

  Future<File> vaultFile() async {
    final dir = directory ?? (await getApplicationDocumentsDirectory()).path;
    return File('$dir/vault.bq');
  }

  /// 读取并解密快照原文;文件缺失/密钥错误/数据被篡改均返回 null。
  Future<String?> _readDecrypted(String masterKeyB64) async {
    try {
      final file = await vaultFile();
      if (!await file.exists()) return null;
      return decryptSensitiveData(await file.readAsString(), masterKeyB64);
    } catch (_) {
      return null;
    }
  }

  /// 读取解密后的快照原文(备份串)。文件缺失/密钥错误返回 null。
  Future<String?> loadVault(String masterKeyB64) => _readDecrypted(masterKeyB64);

  /// 加密并写入快照(目录不存在时自动创建)。注意:会覆盖本地库对象,两者互斥。
  Future<void> saveVault(String backupJson, String masterKeyB64) async {
    final file = await vaultFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(encryptSensitiveData(backupJson, masterKeyB64));
  }

  /// 读取本地库对象(解密 + JSON 解码)。无文件/密钥错误 → null。
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
  Future<void> saveLocalData(
    Map<String, dynamic> data,
    String masterKeyB64, {
    String? salt,
  }) async {
    if (salt != null) data['salt'] = salt;
    final file = await vaultFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(encryptSensitiveData(jsonEncode(data), masterKeyB64));
  }

  /// 从本地库对象读取 salt(跨设备恢复用);旧版备份串/无 salt → null。
  Future<String?> readSalt(String masterKeyB64) async {
    final data = await loadLocalData(masterKeyB64);
    return data?['salt']?.toString();
  }

  /// 删除本地快照(存在才删)。
  Future<void> clearVault() async {
    final file = await vaultFile();
    if (await file.exists()) await file.delete();
  }
}

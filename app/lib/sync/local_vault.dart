import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../crypto/asset_crypto.dart';

/// 本地加密快照:单文件存储最近一次全量备份 JSON(AES-256-GCM 加密)。
/// 未登录时同步/恢复的数据来源与落点;登录后由主页刷新保持最新。
class LocalVault {
  LocalVault({this.directory});

  /// 测试可注入临时目录;默认使用应用文档目录。
  final String? directory;

  Future<File> vaultFile() async {
    final dir = directory ?? (await getApplicationDocumentsDirectory()).path;
    return File('$dir/vault.bq');
  }

  /// 读取并解密快照;文件缺失/密钥错误/数据被篡改均返回 null。
  Future<String?> loadVault(String masterKeyB64) async {
    try {
      final file = await vaultFile();
      if (!await file.exists()) return null;
      return decryptSensitiveData(await file.readAsString(), masterKeyB64);
    } catch (_) {
      return null;
    }
  }

  /// 加密并写入快照(目录不存在时自动创建)。
  Future<void> saveVault(String backupJson, String masterKeyB64) async {
    final file = await vaultFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(encryptSensitiveData(backupJson, masterKeyB64));
  }

  /// 删除本地快照(存在才删)。
  Future<void> clearVault() async {
    final file = await vaultFile();
    if (await file.exists()) await file.delete();
  }
}

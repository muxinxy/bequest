import 'dart:convert';

import '../l10n/app_l10n.dart';
import '../storage/secure_store.dart';
import '../sync/local_vault.dart';
import 'key_derivation.dart';

/// 用旧主密钥解密本地库,再用新主密钥+新盐重新加密(salt 一并写入快照)。
///
/// 文件缺失 / 旧密钥错误 / 数据非本地库对象(旧版备份串,避免覆盖备份)
/// → 返回 false 且不触碰原文件。绝不抛异常。
Future<bool> reencryptVault({
  required String oldMk,
  required String newMk,
  required String newSalt,
  LocalVault? vault,
}) async {
  final v = vault ?? LocalVault();
  final raw = await v.loadVault(oldMk);
  if (raw == null) return false;
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return false;
  }
  // 仅重加密本地库对象;旧版纯备份串不在此处处理,避免覆盖备份。
  if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) return false;
  try {
    await v.saveLocalData(decoded, newMk, salt: newSalt);
    return true;
  } catch (_) {
    return false;
  }
}

/// 修改主密码的本地部分:校验旧主密码 → 派生新密钥 → 重加密本地库 →
/// 更新 SecureStore(密钥/盐/提示语)。
///
/// [verifyOld] 注入以复用限流包装(页面传 guardedVerifyMasterPassword)。
/// [newPassword] 为空时**不修改主密码**(保持原密钥/盐),仅更新提示语——
/// 用于"只改主密码提示语"的场景。
/// 返回 (ok, error, newMk);error 为 null 且 ok=false 表示旧主密码校验失败
/// (限流消息已由调用方提示);云端同步由调用方完成,以便区分 401/网络错误。
Future<({bool ok, String? error, String? newMk})> changeMasterPasswordLocal({
  required SecureStore store,
  LocalVault? vault,
  required Future<bool> Function(String password) verifyOld,
  required String oldPassword,
  required String newPassword,
  required String newHint,
}) async {
  if (!await verifyOld(oldPassword)) {
    return (ok: false, error: null, newMk: null);
  }
  final oldMk = await store.readMasterKey();
  if (oldMk == null || oldMk.isEmpty) {
    return (ok: false, error: L10n.tr('未找到当前主密钥,无法修改'), newMk: null);
  }
  final trimmedNew = newPassword.trim();
  if (trimmedNew.isEmpty) {
    // 仅更新提示语,主密码/密钥/盐不变。
    await store.saveMasterHint(newHint);
    return (ok: true, error: null, newMk: oldMk);
  }
  final newSalt = generateSalt();
  final newMk = await deriveMasterKey(trimmedNew, newSalt);
  // 本地库缺失/不可读则跳过重加密(返回 false),不阻断主密码修改。
  await reencryptVault(
    oldMk: oldMk,
    newMk: newMk,
    newSalt: newSalt,
    vault: vault,
  );
  await store.saveMasterSalt(newSalt);
  await store.saveMasterKey(newMk);
  await store.saveMasterHint(newHint);
  return (ok: true, error: null, newMk: newMk);
}

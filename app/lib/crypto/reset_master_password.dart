import 'dart:convert';

import '../api/api_client.dart';
import '../storage/secure_store.dart';
import '../sync/local_vault.dart';
import 'asset_crypto.dart';
import 'key_derivation.dart';

/// 忘记主密码 → 用**账户密码**重置(端到端加密的固有代价:旧敏感数据不可恢复)。
///
/// 服务端契约:复用 `PUT /api/v1/settings/master-key`(账户密码验证 + 换
/// master_key_wrapped),零新增后端 API。
///
/// 重置后:
/// - 云端:新 MK 新 WK 包装上传;所有资产保留元数据(name/分类/到期),
///   敏感凭据清空、换新 AK 重加密(旧 AK 被旧 MK 包着,无法解出)。
/// - 本地:重建空 vault(旧库不可解)。
///
/// 返回 (ok, error, newMk)。
Future<({bool ok, String? error, String? newMk})> resetMasterPassword({
  required SecureStore store,
  required ApiClient api,
  required String jwt,
  required String accountPassword,
  required String newPassword,
  required String newHint,
  LocalVault? vault,
}) async {
  try {
    // 1. 派生新密钥 + 新 WK。
    final newSalt = generateSalt();
    final newMk = await deriveMasterKey(newPassword, newSalt);
    final wrappingKey = generateWrappingKey();
    final wrapped = wrapMasterKey(newMk, wrappingKey);

    // 2. 云端:账户密码验证 + 更新 master_key_wrapped(失败=账户密码错/网络)。
    await api.updateMasterKeyWrapped(jwt, accountPassword, wrapped);
    // 同步新盐:否则服务端盐是旧的,新设备恢复会用旧盐派生 → 误报主密码错误。
    await api.updateMasterSalt(jwt, newSalt);

    // 3. 重加密云端资产:保留元数据,清空凭据,换新 AK。
    final assets = await api.listAssets(jwt);
    for (final a in assets) {
      final id = '${a['id']}';
      try {
        final full = await api.getAsset(jwt, id);
        final assetKey = generateAssetKey();
        final emptyPayload = jsonEncode({'notes': ''});
        await api.updateAsset(jwt, id, {
          'name': full['name']?.toString() ?? '',
          'asset_type': full['asset_type']?.toString() ?? 'physical',
          'category_id': full['category_id'],
          'expiry_date': full['expiry_date'],
          'encrypted_data': encryptSensitiveData(emptyPayload, assetKey),
          'asset_key_wrapped_mk': wrapAssetKey(assetKey, newMk),
          'asset_key_wrapped_wk': wrapAssetKey(assetKey, wrappingKey),
        });
      } catch (_) {
        // 单条失败不阻断整体(该资产凭据维持旧密文,号主无法解,可手动删除重加)。
      }
    }

    // 4. 本地:重建空 vault(旧库不可解,放弃)。
    final v = vault ?? LocalVault();
    await v.clearVault();
    await v.saveLocalData(
      {
        'schema': 1,
        'assets': <Map<String, dynamic>>[],
        'categories': <Map<String, dynamic>>[],
      },
      newMk,
      salt: newSalt,
    );

    // 5. 更新本机密钥/盐/提示语/WK。
    await store.saveMasterSalt(newSalt);
    await store.saveMasterKey(newMk);
    await store.saveMasterHint(newHint);
    await store.saveWrappingKey(wrappingKey);
    return (ok: true, error: null, newMk: newMk);
  } on ApiException catch (e) {
    return (ok: false, error: e.message, newMk: null);
  } catch (_) {
    return (ok: false, error: '重置失败,请检查网络后重试', newMk: null);
  }
}

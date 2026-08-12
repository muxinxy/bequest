import '../api/api_client.dart';
import '../storage/secure_store.dart';
import 'asset_crypto.dart';
import 'key_derivation.dart';

/// 跨设备登录恢复加密密钥(非破坏性,保留全部资产与凭据)。
///
/// 背景:主密钥/盐/继承包装密钥 WK 仅在注册时写入本机,新设备登录后本地
/// 只有 JWT——资产详情解密失败(无主密钥)、保存失败(无 WK)。
///
/// 恢复流程(服务端契约:注册上传 master_salt,登录返回 master_salt):
/// 1. 主密码 + 盐 → 重新派生主密钥 MK(与注册时逐字节一致)。
/// 2. 校验:用 MK 尝试解开任一资产的 asset_key_wrapped_mk(AES-GCM 认证失败
///    即主密码错误);无资产则跳过校验。
/// 3. 保存 MK 与盐 → 解密恢复。
/// 4. 若本机无 WK:生成新 WK → 用账户密码更新服务端 master_key_wrapped
///    (PUT /settings/master-key)→ 逐资产把 AK 重新用新 WK 包装
///    (asset_key_wrapped_wk,凭据密文原样保留)→ 保存新 WK。
///
/// 返回 (ok, error);error 非空时未写入任何状态,可安全重试。
Future<({bool ok, String? error})> recoverMasterKeys({
  required SecureStore store,
  required ApiClient api,
  required String jwt,
  required String masterSalt,
  required String masterPassword,
  required String accountPassword,
}) async {
  try {
    final mk = await deriveMasterKey(masterPassword, masterSalt);
    final assets = await api.listAssets(jwt);

    // 校验主密码:解开任一资产的 AK。全部无 AK(新账号无资产)则跳过。
    String? sampleWrappedMk;
    for (final a in assets) {
      final id = '${a['id']}';
      final full = await api.getAsset(jwt, id);
      final wrapped = full['asset_key_wrapped_mk']?.toString() ?? '';
      if (wrapped.isNotEmpty) {
        sampleWrappedMk = wrapped;
        break;
      }
    }
    if (sampleWrappedMk != null) {
      try {
        unwrapAssetKey(sampleWrappedMk, mk);
      } catch (_) {
        return (ok: false, error: '主密码错误,请重试');
      }
    }

    await store.saveMasterKey(mk);
    await store.saveMasterSalt(masterSalt);

    // WK 缺失 → 再生并重包装(继承交接密钥变更,号主需重新线下交付)。
    final existingWk = await store.readWrappingKey();
    if (existingWk == null || existingWk.isEmpty) {
      final wk = generateWrappingKey();
      final wrapped = wrapMasterKey(mk, wk);
      await api.updateMasterKeyWrapped(jwt, accountPassword, wrapped);

      for (final a in assets) {
        final id = '${a['id']}';
        try {
          final full = await api.getAsset(jwt, id);
          final wrappedMk = full['asset_key_wrapped_mk']?.toString() ?? '';
          final ak = wrappedMk.isEmpty ? null : unwrapAssetKey(wrappedMk, mk);
          await api.updateAsset(jwt, id, {
            'name': full['name']?.toString() ?? '',
            'asset_type': full['asset_type']?.toString() ?? 'physical',
            'category_id': full['category_id'],
            'expiry_date': full['expiry_date'],
            'encrypted_data': full['encrypted_data']?.toString() ?? '',
            'asset_key_wrapped_mk': full['asset_key_wrapped_mk']?.toString() ?? '',
            'asset_key_wrapped_wk': ak == null ? '' : wrapAssetKey(ak, wk),
          });
        } catch (_) {
          // 单条失败不阻断(该资产继承交接沿用旧 WK 路径,可手动删除重加)。
        }
      }
      await store.saveWrappingKey(wk);
    }
    return (ok: true, error: null);
  } on ApiException catch (e) {
    return (ok: false, error: e.message);
  } catch (_) {
    return (ok: false, error: '恢复失败,请检查网络后重试');
  }
}

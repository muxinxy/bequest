import '../storage/secure_store.dart';
import '../sync/local_vault.dart';
import 'asset_repository.dart';
import 'cloud_asset_repository.dart';
import 'local_asset_repository.dart';

/// 当前存储模式对应的仓储:云模式需要 jwt,本地模式需要主密钥。
class RepositoryFactory {
  static Future<AssetRepository> resolve({
    required String? jwt,
    required String masterKeyB64,
    LocalVault? vault,
  }) async {
    final mode = await SecureStore().readStorageMode();
    if (jwt != null && mode != 'local') return CloudAssetRepository.create(jwt: jwt);
    return LocalAssetRepository(masterKeyB64: masterKeyB64, vault: vault);
  }
}

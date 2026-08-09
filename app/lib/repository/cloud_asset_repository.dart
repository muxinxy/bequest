import 'package:http/http.dart' as http;

import '../api/api_client.dart';
import '../api/api_config.dart';
import 'asset_repository.dart';

/// 云模式:委托 ApiClient(需要 jwt)。
///
/// 用静态工厂 [CloudAssetRepository.create] 异步解析配置的 baseUrl;
/// 也可用普通构造直接传入已解析好的 baseUrl(测试/离线场景)。
class CloudAssetRepository implements AssetRepository {
  CloudAssetRepository({required this.jwt, String? baseUrl, http.Client? client})
      : _api = ApiClient(client: client, baseUrl: baseUrl);

  /// 解析 ApiConfig.baseUrl() 后构造(设置页可覆盖服务器地址)。
  static Future<CloudAssetRepository> create({
    required String jwt,
    http.Client? client,
  }) async {
    return CloudAssetRepository(
      jwt: jwt,
      baseUrl: await ApiConfig.baseUrl(),
      client: client,
    );
  }

  final String jwt;
  final ApiClient _api;

  @override
  Future<List<Map<String, dynamic>>> listCategories() =>
      _api.listCategories(jwt);

  @override
  Future<Map<String, dynamic>> createCategory(String name) =>
      _api.createCategory(jwt, name);

  @override
  Future<void> deleteCategory(String id) => _api.deleteCategory(jwt, id);

  @override
  Future<List<Map<String, dynamic>>> listAssets() => _api.listAssets(jwt);

  @override
  Future<Map<String, dynamic>> getAsset(String id) => _api.getAsset(jwt, id);

  @override
  Future<Map<String, dynamic>> createAsset(Map<String, dynamic> body) =>
      _api.createAsset(jwt, body);

  @override
  Future<Map<String, dynamic>> updateAsset(
          String id, Map<String, dynamic> body) =>
      _api.updateAsset(jwt, id, body);

  @override
  Future<void> deleteAsset(String id) => _api.deleteAsset(jwt, id);
}

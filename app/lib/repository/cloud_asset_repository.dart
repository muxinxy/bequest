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
  Future<Map<String, dynamic>> createCategory(String name, {String assetType = 'physical'}) =>
      _api.createCategory(jwt, name, assetType: assetType);

  @override
  Future<Map<String, dynamic>> updateCategory(
          String id, Map<String, dynamic> body) =>
      _api.updateCategory(jwt, id, body);

  @override
  Future<void> deleteCategory(String id, {String? moveTo}) =>
      _api.deleteCategory(jwt, id, moveTo: moveTo == null ? null : int.tryParse(moveTo));

  @override
  Future<void> reorderCategories(List<String> ids) =>
      _api.reorderCategories(jwt, ids.map(int.parse).toList());

  @override
  Future<Map<String, dynamic>> moveAssets(List<String> ids, String? categoryId) =>
      _api.moveAssets(jwt, ids.map(int.parse).toList(), categoryId == null ? null : int.tryParse(categoryId));

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

  @override
  Future<int> batchDeleteAssets(List<String> ids) async {
    final res = await _api.batchDeleteAssets(jwt, ids.map(int.parse).toList());
    return (res['deleted'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<Map<String, dynamic>> copyAsset(String id) => _api.copyAsset(jwt, id);

  @override
  Future<List<Map<String, dynamic>>> listAssetInheritors(String assetId) =>
      _api.listAssetInheritors(jwt, assetId);

  @override
  Future<Map<String, dynamic>> createAssetInheritor(
          String assetId, Map<String, dynamic> body) =>
      _api.createAssetInheritor(jwt, assetId, body);

  @override
  Future<void> deleteAssetInheritor(String assetId, String iid) =>
      _api.deleteAssetInheritor(jwt, assetId, iid);

  @override
  Future<void> updateAssetInheritorLadder(
          String assetId, String iid, int? ladderId) =>
      _api.updateAssetInheritorLadder(jwt, assetId, iid, ladderId);

  @override
  Future<List<Map<String, dynamic>>> listCategoryInheritors(String categoryId) =>
      _api.listCategoryInheritors(jwt, categoryId);

  @override
  Future<Map<String, dynamic>> createCategoryInheritor(
          String categoryId, Map<String, dynamic> body) =>
      _api.createCategoryInheritor(jwt, categoryId, body);

  @override
  Future<void> deleteCategoryInheritor(String categoryId, String iid) =>
      _api.deleteCategoryInheritor(jwt, categoryId, iid);

  @override
  Future<void> updateCategoryInheritorLadder(
          String categoryId, String iid, int? ladderId) =>
      _api.updateCategoryInheritorLadder(jwt, categoryId, iid, ladderId);

  @override
  Future<List<Map<String, dynamic>>> listInheritorAssets(String inheritorId) =>
      _api.listInheritorAssets(jwt, inheritorId);

  @override
  Future<Map<String, dynamic>> listCategoryInheritorAssets(
          String categoryId, String iid) =>
      _api.listCategoryInheritorAssets(jwt, categoryId, iid);
}

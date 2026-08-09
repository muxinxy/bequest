/// 资产/分类数据源抽象:云端与本地模式共用同一接口。
/// 所有方法返回服务器形状的 map;id 一律为 String。
abstract class AssetRepository {
  Future<List<Map<String, dynamic>>> listCategories();
  Future<Map<String, dynamic>> createCategory(String name);
  Future<void> deleteCategory(String id);
  Future<List<Map<String, dynamic>>> listAssets(); // metadata only
  Future<Map<String, dynamic>> getAsset(String id); // incl encrypted_data
  Future<Map<String, dynamic>> createAsset(Map<String, dynamic> body);
  Future<Map<String, dynamic>> updateAsset(String id, Map<String, dynamic> body);
  Future<void> deleteAsset(String id);
}

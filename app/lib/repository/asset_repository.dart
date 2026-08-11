/// 资产/分类数据源抽象:云端与本地模式共用同一接口。
/// 所有方法返回服务器形状的 map;id 一律为 String。
abstract class AssetRepository {
  Future<List<Map<String, dynamic>>> listCategories();
  Future<Map<String, dynamic>> createCategory(String name, {String assetType = 'physical'});
  Future<Map<String, dynamic>> updateCategory(String id, Map<String, dynamic> body);
  Future<void> deleteCategory(String id);
  Future<List<Map<String, dynamic>>> listAssets(); // metadata only
  Future<Map<String, dynamic>> getAsset(String id); // incl encrypted_data
  Future<Map<String, dynamic>> createAsset(Map<String, dynamic> body);
  Future<Map<String, dynamic>> updateAsset(String id, Map<String, dynamic> body);
  Future<void> deleteAsset(String id);
  // 资产级继承人绑定(仅云端模式支持;本地模式返回空/抛错)。
  Future<List<Map<String, dynamic>>> listAssetInheritors(String assetId);
  Future<Map<String, dynamic>> createAssetInheritor(String assetId, Map<String, dynamic> body);
  Future<void> deleteAssetInheritor(String assetId, String iid);
  // 分组(分类)级继承人绑定。
  Future<List<Map<String, dynamic>>> listCategoryInheritors(String categoryId);
  Future<Map<String, dynamic>> createCategoryInheritor(String categoryId, Map<String, dynamic> body);
  Future<void> deleteCategoryInheritor(String categoryId, String iid);
  // 某继承人绑定的所有资产(直接 + 经分组)。
  Future<List<Map<String, dynamic>>> listInheritorAssets(String inheritorId);
}

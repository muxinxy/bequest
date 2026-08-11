import '../sync/local_vault.dart';
import 'asset_repository.dart';

/// 本地模式:数据存于 LocalVault 加密的本地库对象,不依赖网络。
///
/// id 形如 'L<毫秒时间戳><自增序号>',进程内唯一且稳定;
/// created_at/updated_at 与服务器同格式 'YYYY-MM-DD HH:MM:SS'。
class LocalAssetRepository implements AssetRepository {
  LocalAssetRepository({required this.masterKeyB64, LocalVault? vault})
      : _vault = vault ?? LocalVault();

  final String masterKeyB64;
  final LocalVault _vault;

  String? _salt;
  int _seq = 0;

  /// 读取本地库对象;无文件时返回全新空库。
  Future<Map<String, dynamic>> _load() async {
    final data = await _vault.loadLocalData(masterKeyB64);
    if (data == null) {
      return {
        'schema': 1,
        'assets': <Map<String, dynamic>>[],
        'categories': <Map<String, dynamic>>[],
      };
    }
    _salt ??= data['salt']?.toString();
    return data;
  }

  /// 保存本地库对象,携带已记住的 salt。
  Future<void> _save(Map<String, dynamic> data) =>
      _vault.saveLocalData(data, masterKeyB64, salt: _salt);

  String _newId() => 'L${DateTime.now().millisecondsSinceEpoch}${++_seq}';

  String _nowString() {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  List<Map<String, dynamic>> _asMaps(dynamic list) =>
      (list as List).whereType<Map<String, dynamic>>().toList();

  @override
  Future<List<Map<String, dynamic>>> listCategories() async =>
      _asMaps((await _load())['categories']);

  @override
  Future<Map<String, dynamic>> createCategory(
    String name, {
    String assetType = 'physical',
  }) async {
    final data = await _load();
    final category = <String, dynamic>{
      'id': _newId(),
      'name': name,
      'asset_type': assetType,
      'is_preset': 0,
      'created_at': _nowString(),
    };
    (data['categories'] as List).add(category);
    await _save(data);
    return category;
  }

  @override
  Future<Map<String, dynamic>> updateCategory(
    String id,
    Map<String, dynamic> body,
  ) async {
    final data = await _load();
    final categories = data['categories'] as List;
    final index = categories.indexWhere((c) => '${(c as Map)['id']}' == id);
    if (index < 0) throw StateError('分类不存在(id: $id)');
    final old = categories[index] as Map<String, dynamic>;
    // 服务器形状:name/asset_type,保留 id/created_at。
    final updated = <String, dynamic>{
      'id': id,
      'name': body['name']?.toString() ?? old['name']?.toString() ?? '',
      'asset_type': body['asset_type']?.toString() ??
          old['asset_type']?.toString() ??
          'physical',
      'is_preset': old['is_preset'] ?? 0,
      'created_at': old['created_at']?.toString(),
    };
    categories[index] = updated;
    await _save(data);
    return updated;
  }

  @override
  Future<void> deleteCategory(String id) async {
    final data = await _load();
    (data['categories'] as List)
        .removeWhere((c) => '${(c as Map)['id']}' == id);
    // 镜像服务器 ON DELETE SET NULL:引用该分类的资产解除关联。
    for (final asset in _asMaps(data['assets'])) {
      if ('${asset['category_id']}' == id) asset['category_id'] = null;
    }
    await _save(data);
  }

  @override
  Future<List<Map<String, dynamic>>> listAssets() async =>
      _asMaps((await _load())['assets']);

  @override
  Future<Map<String, dynamic>> getAsset(String id) async {
    for (final asset in _asMaps((await _load())['assets'])) {
      if ('${asset['id']}' == id) return asset;
    }
    throw StateError('资产不存在(id: $id)');
  }

  @override
  Future<Map<String, dynamic>> createAsset(Map<String, dynamic> body) async {
    final data = await _load();
    final now = _nowString();
    final asset = <String, dynamic>{
      ...body,
      'id': _newId(),
      'created_at': now,
      'updated_at': now,
    };
    (data['assets'] as List).add(asset);
    await _save(data);
    return asset;
  }

  @override
  Future<Map<String, dynamic>> updateAsset(
    String id,
    Map<String, dynamic> body,
  ) async {
    final data = await _load();
    final assets = data['assets'] as List;
    final index = assets.indexWhere((a) => '${(a as Map)['id']}' == id);
    if (index < 0) throw StateError('资产不存在(id: $id)');
    final old = assets[index] as Map<String, dynamic>;
    // 服务器形状:name/asset_type/category_id/encrypted_data/expiry_date。
    final updated = <String, dynamic>{
      'id': id,
      'name': body['name']?.toString() ?? old['name']?.toString() ?? '',
      'asset_type': body['asset_type']?.toString() ??
          old['asset_type']?.toString() ??
          'physical',
      'category_id': body.containsKey('category_id')
          ? body['category_id']?.toString()
          : old['category_id']?.toString(),
      'encrypted_data': body['encrypted_data']?.toString() ??
          old['encrypted_data']?.toString(),
      'expiry_date': body.containsKey('expiry_date')
          ? body['expiry_date']?.toString()
          : old['expiry_date']?.toString(),
      'created_at': old['created_at']?.toString(),
      'updated_at': _nowString(),
    };
    assets[index] = updated;
    await _save(data);
    return updated;
  }

  @override
  Future<void> deleteAsset(String id) async {
    final data = await _load();
    (data['assets'] as List).removeWhere((a) => '${(a as Map)['id']}' == id);
    await _save(data);
  }

  // 本地模式无继承概念:继承人绑定为空列表(避免 UI 崩溃),写操作抛错。
  @override
  Future<List<Map<String, dynamic>>> listAssetInheritors(String assetId) async =>
      const [];

  @override
  Future<Map<String, dynamic>> createAssetInheritor(
      String assetId, Map<String, dynamic> body) {
    throw UnsupportedError('本地模式不支持资产级继承人设置');
  }

  @override
  Future<void> deleteAssetInheritor(String assetId, String iid) {
    throw UnsupportedError('本地模式不支持资产级继承人设置');
  }

  @override
  Future<List<Map<String, dynamic>>> listCategoryInheritors(
      String categoryId) async => const [];

  @override
  Future<Map<String, dynamic>> createCategoryInheritor(
      String categoryId, Map<String, dynamic> body) {
    throw UnsupportedError('本地模式不支持分组级继承人设置');
  }

  @override
  Future<void> deleteCategoryInheritor(String categoryId, String iid) {
    throw UnsupportedError('本地模式不支持分组级继承人设置');
  }

  @override
  Future<List<Map<String, dynamic>>> listInheritorAssets(
      String inheritorId) async => const [];
}

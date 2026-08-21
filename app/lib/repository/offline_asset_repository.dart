import 'dart:convert';

import '../sync/local_vault.dart';
import 'asset_repository.dart';

/// 离线只读仓储:从本地缓存快照(备份 JSON)读取资产/分类,
/// 供服务器不可达时查看/导出。所有写操作抛 UnsupportedError。
class OfflineAssetRepository implements AssetRepository {
  OfflineAssetRepository({required this.masterKeyB64, LocalVault? vault})
      : _vault = vault ?? LocalVault();

  final String masterKeyB64;
  final LocalVault _vault;

  Map<String, dynamic>? _cache;
  Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    final raw = await _vault.loadVault(masterKeyB64);
    if (raw == null) {
      _cache = {
        'assets': <Map<String, dynamic>>[],
        'categories': <Map<String, dynamic>>[],
      };
      return _cache!;
    }
    final decoded = jsonDecode(raw);
    _cache = decoded is Map<String, dynamic> ? decoded : {
      'assets': <Map<String, dynamic>>[],
      'categories': <Map<String, dynamic>>[],
    };
    return _cache!;
  }

  @override
  Future<List<Map<String, dynamic>>> listCategories() async =>
      ((await _load())['categories'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
  @override
  Future<List<Map<String, dynamic>>> listAssets() async =>
      ((await _load())['assets'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  @override
  Future<Map<String, dynamic>> getAsset(String id) async {
    for (final a in await listAssets()) {
      if ('${a['id']}' == id) return a;
    }
    throw StateError('资产不存在(id: $id)');
  }

  // 离线只读:全部写操作不支持。
  @override
  Future<Map<String, dynamic>> createCategory(String name, {String assetType = 'physical'}) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<Map<String, dynamic>> updateCategory(String id, Map<String, dynamic> body) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<void> deleteCategory(String id, {String? moveTo}) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<void> reorderCategories(List<String> ids) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<Map<String, dynamic>> moveAssets(List<String> ids, String? categoryId) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<Map<String, dynamic>> createAsset(Map<String, dynamic> body) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<Map<String, dynamic>> updateAsset(String id, Map<String, dynamic> body) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<void> deleteAsset(String id) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<int> batchDeleteAssets(List<String> ids) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<Map<String, dynamic>> copyAsset(String id) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<List<Map<String, dynamic>>> listAssetInheritors(String assetId) async => const [];
  @override
  Future<Map<String, dynamic>> createAssetInheritor(String assetId, Map<String, dynamic> body) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<void> deleteAssetInheritor(String assetId, String iid) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<List<Map<String, dynamic>>> listCategoryInheritors(String categoryId) async => const [];
  @override
  Future<Map<String, dynamic>> createCategoryInheritor(String categoryId, Map<String, dynamic> body) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<void> deleteCategoryInheritor(String categoryId, String iid) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<List<Map<String, dynamic>>> listInheritorAssets(String inheritorId) async => const [];
  @override
  Future<Map<String, dynamic>> listCategoryInheritorAssets(String categoryId, String iid) async =>
      const {'assets': <Map<String, dynamic>>[]};
}

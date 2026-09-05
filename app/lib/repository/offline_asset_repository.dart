import 'dart:convert';

import '../l10n/app_l10n.dart';
import '../sync/local_vault.dart';
import 'asset_repository.dart';

/// 离线只读仓储:从本地缓存快照(备份 JSON)读取资产/分类/继承人/操作记录,
/// 供服务器不可达时查看/导出。所有写操作抛 UnsupportedError。
class OfflineAssetRepository implements AssetRepository {
  OfflineAssetRepository({required this.masterKeyB64, LocalVault? vault})
      : _vault = vault ?? LocalVault();

  final String masterKeyB64;
  final LocalVault _vault;

  Map<String, dynamic>? _cache;
  static Map<String, dynamic> _empty() => {
        'assets': <Map<String, dynamic>>[],
        'categories': <Map<String, dynamic>>[],
        'inheritors': <Map<String, dynamic>>[],
        'logs': <Map<String, dynamic>>[],
      };
  Future<Map<String, dynamic>> _load() async {
    if (_cache != null) return _cache!;
    final raw = await _vault.loadVault(masterKeyB64);
    if (raw == null) {
      _cache = _empty();
      return _cache!;
    }
    final decoded = jsonDecode(raw);
    _cache = decoded is Map<String, dynamic> ? decoded : _empty();
    return _cache!;
  }

  @override
  Future<List<Map<String, dynamic>>> listCategories({String q = ''}) async {
    final all = ((await _load())['categories'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    if (q.isEmpty) return all;
    final query = q.toLowerCase();
    return all
        .where((c) => '${c['name']}'.toLowerCase().contains(query))
        .toList();
  }

  @override
  Future<(List<Map<String, dynamic>>, int)> listCategoriesPaged({
    String q = '',
    int limit = 50,
    int offset = 0,
  }) async {
    // 离线数据量小:忽略分页参数,全量返回。
    final items = await listCategories(q: q);
    return (items, items.length);
  }
  @override
  Future<List<Map<String, dynamic>>> listAssets() async =>
      ((await _load())['assets'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  @override
  Future<(List<Map<String, dynamic>>, int)> listAssetsPaged({
    String? categoryId,
    String q = '',
    int limit = 50,
    int offset = 0,
  }) async {
    // 离线数据量小:忽略分页参数,全量拉取后按分组过滤 + 名称搜索。
    var items = filterAssetsByCategory(await listAssets(), categoryId);
    if (q.isNotEmpty) {
      final query = q.toLowerCase();
      items = items
          .where((a) => '${a['name']}'.toLowerCase().contains(query))
          .toList();
    }
    return (items, items.length);
  }

  /// 缓存的继承人列表(含 access_code/计数),断网可查看。
  Future<List<Map<String, dynamic>>> listInheritors() async =>
      ((await _load())['inheritors'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  /// 缓存的操作记录(最近 200 条,全部类型)。
  Future<List<Map<String, dynamic>>> listLogs() async =>
      ((await _load())['logs'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  /// 统一入口:读缓存操作记录(供操作记录页离线显示)。
  Future<List<Map<String, dynamic>>> readLogsFromCache() => listLogs();

  /// 统一入口:更新缓存操作记录(云端加载成功后写入)。
  Future<void> writeLogsToCache(List<Map<String, dynamic>> logs) async {
    final data = await _load();
    data['logs'] = logs;
    await _vault.saveVaultBounded(jsonEncode(data), masterKeyB64);
  }

  @override
  Future<Map<String, dynamic>> getAsset(String id) async {
    for (final a in await listAssets()) {
      if ('${a['id']}' == id) return a;
    }
    throw StateError(L10n.trp('资产不存在(id: {id})', {'id': id}));
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
  Future<void> updateAssetInheritorLadder(String assetId, String iid, int? ladderId) =>
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
  Future<void> updateCategoryInheritorLadder(String categoryId, String iid, int? ladderId) =>
      Future.error(UnsupportedError('离线模式不可修改'));
  @override
  Future<List<Map<String, dynamic>>> listInheritorAssets(String inheritorId) async => const [];
  @override
  Future<Map<String, dynamic>> listCategoryInheritorAssets(String categoryId, String iid) async =>
      const {'assets': <Map<String, dynamic>>[]};
}

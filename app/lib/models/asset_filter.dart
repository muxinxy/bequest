/// 主页资产过滤的纯函数:类型 / 分类 / 名称搜索,便于单元测试。
/// 入参为服务器形状的资产 map(含 name/asset_type/category_id)。
library;

/// 分类下拉的'全部'哨兵:不过滤。
const String kAllFilter = '全部';

/// 分类下拉的'未分类'哨兵:匹配无分类资产。
const String kUncategorizedFilter = '未分类';

/// 依过滤条件筛选资产;名称搜索不区分大小写。
/// [typeFilter] 为 'physical'/'virtual' 或 null(全部);
/// [categoryFilter] 为分类 id、[kUncategorizedFilter] 或 null(全部)。
List<Map<String, dynamic>> filterAssets({
  required List<Map<String, dynamic>> assets,
  String? typeFilter,
  String? categoryFilter,
  String search = '',
}) {
  final query = search.trim().toLowerCase();
  return assets.where((a) {
    if (typeFilter != null && typeFilter != kAllFilter) {
      if (a['asset_type']?.toString() != typeFilter) return false;
    }
    final categoryId = a['category_id']?.toString();
    if (categoryFilter == kUncategorizedFilter) {
      if (categoryId != null && categoryId.isNotEmpty) return false;
    } else if (categoryFilter != null && categoryFilter != kAllFilter) {
      if (categoryId != categoryFilter) return false;
    }
    if (query.isNotEmpty) {
      final name = a['name']?.toString().toLowerCase() ?? '';
      if (!name.contains(query)) return false;
    }
    return true;
  }).toList(growable: false);
}

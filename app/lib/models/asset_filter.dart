/// 主页资产过滤的纯函数:类型 / 分组 / 名称搜索,便于单元测试。
/// 入参为服务器形状的资产 map(含 name/asset_type/category_id)。
library;

/// 分组下拉'全部'哨兵:不过滤。
const String kAllFilter = '全部';

/// 分组下拉'未分组'哨兵:匹配无分组资产。
const String kUncategorizedFilter = '未分组';

/// 依过滤条件筛选资产。名称搜索不区分大小写;
/// 传入 [categoryNames](分组 id → 名称)时搜索同时匹配**分组名**。
/// [typeFilter] 为 'physical'/'virtual' 或 null(全部);
/// [categoryFilter] 为分组 id、[kUncategorizedFilter] 或 null(全部)。
List<Map<String, dynamic>> filterAssets({
  required List<Map<String, dynamic>> assets,
  String? typeFilter,
  String? categoryFilter,
  String search = '',
  Map<String, String> categoryNames = const {},
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
      if (name.contains(query)) return true;
      // 搜索分组名:资产所属分组名包含查询词也命中。
      if (categoryId != null && categoryId.isNotEmpty) {
        final catName = categoryNames[categoryId]?.toLowerCase() ?? '';
        if (catName.contains(query)) return true;
      }
      return false;
    }
    return true;
  }).toList(growable: false);
}

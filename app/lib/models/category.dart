/// 分类。注册时服务端会为用户预置 10 个预设分类
/// (is_preset=true, 实体/虚拟各 5 个),与自定义分类同样可改名/改类型/删除。
class Category {
  const Category({
    required this.id,
    required this.name,
    this.assetType = 'physical',
    this.isPreset = false,
    this.createdAt,
  });

  factory Category.fromJson(Map<String, dynamic> json) => Category(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        assetType: json['asset_type']?.toString() ?? 'physical',
        isPreset: json['is_preset'] == 1 || json['is_preset'] == true,
        createdAt: json['created_at']?.toString(),
      );

  final String id;
  final String name;
  final String assetType; // physical | virtual
  final bool isPreset;
  final String? createdAt;
}

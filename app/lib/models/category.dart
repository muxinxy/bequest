/// 服务器分类(自定义分类)。
class Category {
  const Category({required this.id, required this.name, this.createdAt});

  factory Category.fromJson(Map<String, dynamic> json) => Category(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        createdAt: json['created_at']?.toString(),
      );

  final String id;
  final String name;
  final String? createdAt;
}

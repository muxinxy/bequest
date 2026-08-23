/// 继承人。
class Inheritor {
  const Inheritor({
    required this.id,
    required this.name,
    required this.email,
    this.phone = '',
    this.priority,
    this.createdAt,
    this.assetCount = 0,
    this.categoryCount = 0,
    this.accessCode = '',
  });

  factory Inheritor.fromJson(Map<String, dynamic> json) => Inheritor(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        phone: json['phone']?.toString() ?? '',
        priority: (json['priority'] as num?)?.toInt(),
        createdAt: json['created_at']?.toString(),
        assetCount: (json['asset_count'] as num?)?.toInt() ?? 0,
        categoryCount: (json['category_count'] as num?)?.toInt() ?? 0,
        accessCode: json['access_code']?.toString() ?? '',
      );

  final String id;
  final String name;
  final String email;

  /// 手机号(可选;邮箱或手机号至少一个)。
  final String phone;
  final int? priority;
  final String? createdAt;

  /// 该继承人绑定的资产数、分组数(服务端统计)。
  final int assetCount;
  final int categoryCount;

  /// 明文继承码(触发继承后凭此码领取密钥)。
  final String accessCode;
}

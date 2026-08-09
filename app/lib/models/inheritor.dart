/// 继承人。
class Inheritor {
  const Inheritor({
    required this.id,
    required this.name,
    required this.email,
    this.priority,
    this.createdAt,
  });

  factory Inheritor.fromJson(Map<String, dynamic> json) => Inheritor(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        priority: (json['priority'] as num?)?.toInt(),
        createdAt: json['created_at']?.toString(),
      );

  final String id;
  final String name;
  final String email;
  final int? priority;
  final String? createdAt;
}

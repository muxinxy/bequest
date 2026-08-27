/// 提醒模板。is_preset=1 为系统模板,只读。
/// type: expiry(资产到期) | escalation(未登录升级) | inheritance(继承事件)。
class ReminderTemplate {
  const ReminderTemplate({
    required this.id,
    required this.name,
    this.titleTemplate,
    this.bodyTemplate,
    this.isPreset = false,
    this.type = 'expiry',
    this.isDefault = false,
    this.createdAt,
  });

  factory ReminderTemplate.fromJson(Map<String, dynamic> json) =>
      ReminderTemplate(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        titleTemplate: json['title_template']?.toString(),
        bodyTemplate: json['body_template']?.toString(),
        isPreset: json['is_preset'] == 1 || json['is_preset'] == true,
        type: json['type']?.toString() ?? 'expiry',
        isDefault: json['is_default'] == 1 || json['is_default'] == true,
        createdAt: json['created_at']?.toString(),
      );

  final String id;
  final String name;
  final String? titleTemplate;
  final String? bodyTemplate;
  final bool isPreset;
  final String type;
  final bool isDefault;
  final String? createdAt;
}

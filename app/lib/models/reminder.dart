/// 站内提醒。
/// type: expiry(到期) | escalation(升级) | inheritance(继承);
/// status: pending(未读) | read(已读)。
class Reminder {
  const Reminder({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.status,
    this.createdAt,
  });

  factory Reminder.fromJson(Map<String, dynamic> json) => Reminder(
        id: json['id']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        body: json['body']?.toString() ?? '',
        status: json['status']?.toString() ?? 'pending',
        createdAt: json['created_at']?.toString(),
      );

  final String id;
  final String type;
  final String title;
  final String body;
  final String status;
  final String? createdAt;

  bool get isUnread => status == 'pending';
}

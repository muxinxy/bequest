/// 继承状态。
/// stage: inactive(未触发) | warning(提醒中) | triggered(已触发)
///       | claimed(已领取) | reversed(已撤销)。
class InheritanceStatus {
  const InheritanceStatus({
    this.stage,
    this.escalationLevel,
    this.lastLoginAt,
    this.events = const [],
  });

  factory InheritanceStatus.fromJson(Map<String, dynamic> json) =>
      InheritanceStatus(
        stage: json['stage']?.toString(),
        escalationLevel: (json['escalation_level'] as num?)?.toInt(),
        lastLoginAt: json['last_login_at']?.toString(),
        events: (json['events'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(InheritanceEvent.fromJson)
                .toList(growable: false) ??
            const [],
      );

  final String? stage;
  final int? escalationLevel;
  final String? lastLoginAt;
  final List<InheritanceEvent> events;
}

/// 一次继承事件。
class InheritanceEvent {
  const InheritanceEvent({
    required this.id,
    required this.status,
    this.createdAt,
    this.claimedAt,
    this.reversedAt,
    this.reversableUntil,
  });

  factory InheritanceEvent.fromJson(Map<String, dynamic> json) =>
      InheritanceEvent(
        id: json['id']?.toString() ?? '',
        status: json['status']?.toString() ?? '',
        createdAt: json['created_at']?.toString(),
        claimedAt: json['claimed_at']?.toString(),
        reversedAt: json['reversed_at']?.toString(),
        reversableUntil: json['reversable_until']?.toString(),
      );

  final String id;
  final String status;
  final String? createdAt;
  final String? claimedAt;
  final String? reversedAt;

  /// 领取后的反悔截止时间(72h 窗口);过期后交接最终完成,登录不再撤销。
  final String? reversableUntil;
}

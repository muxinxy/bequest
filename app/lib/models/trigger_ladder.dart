/// 触发阶梯:号主连续未登录天数升级序列(如 30/60/90)。
class TriggerLadder {
  const TriggerLadder({
    required this.id,
    required this.name,
    required this.isGlobal,
    required this.days,
    this.createdAt,
  });

  factory TriggerLadder.fromJson(Map<String, dynamic> json) => TriggerLadder(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: json['name']?.toString() ?? '',
        isGlobal: json['is_global'] == 1 || json['is_global'] == true,
        days: [
          for (final d in (json['days'] as List? ?? const []))
            (d as num).toInt(),
        ],
        createdAt: json['created_at']?.toString(),
      );

  final int id;
  final String name;

  /// 是否全局阶梯(全局不可删除,删除自定义阶梯后引用它的继承自动回退全局)。
  final bool isGlobal;

  /// 升级天数序列,如 [30, 60, 90]。
  final List<int> days;
  final String? createdAt;

  /// 天数展示文本,如 "30/60/90 天"。
  String get daysLabel => days.isEmpty ? '未设置' : '${days.join('/')} 天';
}
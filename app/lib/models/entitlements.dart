/// 三层权益矩阵。
class Entitlements {
  const Entitlements({
    required this.label,
    this.assetLimit,
    required this.cloudSync,
    required this.inheritance,
    required this.reminderChannels,
    required this.customTemplates,
    required this.exportExcel,
    required this.offlineMode,
  });

  final String label; // 访客/免费用户/会员
  final int? assetLimit; // null = 不限
  final bool cloudSync; // 云端同步
  final bool inheritance; // 继承交接
  final int reminderChannels; // 提醒渠道数(1=站内信,2=+邮件,3=+短信,4=+电话)
  final bool customTemplates; // 自定义提醒模板
  final bool exportExcel; // Excel 导出(预留)
  final bool offlineMode; // 本地模式/自托管

  static const guest = Entitlements(
    label: '访客',
    assetLimit: 20,
    cloudSync: false,
    inheritance: false,
    reminderChannels: 1,
    customTemplates: false,
    exportExcel: false,
    offlineMode: true,
  );

  static const free = Entitlements(
    label: '免费用户',
    assetLimit: 50,
    cloudSync: true,
    inheritance: true,
    reminderChannels: 2,
    customTemplates: true,
    exportExcel: false,
    offlineMode: true,
  );

  static const member = Entitlements(
    label: '会员',
    assetLimit: null,
    cloudSync: true,
    inheritance: true,
    reminderChannels: 4,
    customTemplates: true,
    exportExcel: true,
    offlineMode: true,
  );

  /// 按层级字符串取权益:tier null/'guest' → 访客,'member' → 会员,其余 → 免费用户。
  static Entitlements forTier(String? tier) {
    if (tier == 'member') return member;
    if (tier == null || tier == 'guest') return guest;
    return free;
  }

  /// 结合登录态:未登录必为访客;已登录按 tier(未知层级按免费用户)。
  static Entitlements forJwtAndTier({required bool hasJwt, String? tier}) =>
      !hasJwt ? guest : forTier(tier ?? 'free');
}

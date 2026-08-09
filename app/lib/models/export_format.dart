import 'dart:convert';

/// 导出文件契约(version 1)的构建与解析。纯函数,便于测试。
///
/// 文件格式:
/// `{"app":"bequest","version":1,"exported_at":"<ISO8601>","assets":[`
/// `  {"name","asset_type","category"(可选),"expiry_date"(可选),`
/// `   "credentials"(可空),"notes"(可空),"advance_days"(可选)}`
/// `]}`
class ExportItem {
  const ExportItem({
    required this.name,
    required this.assetType,
    this.category,
    this.expiryDate,
    required this.credentials,
    required this.notes,
    this.advanceDays,
  });

  final String name;
  final String assetType;
  final String? category;
  final String? expiryDate;
  final String credentials;
  final String notes;
  final int? advanceDays;

  Map<String, dynamic> toJson() => {
        'name': name,
        'asset_type': assetType,
        if (category != null) 'category': category,
        if (expiryDate != null) 'expiry_date': expiryDate,
        'credentials': credentials,
        'notes': notes,
        if (advanceDays != null) 'advance_days': advanceDays,
      };
}

/// 构建导出文件 JSON(version 1)。
Map<String, dynamic> buildExportJson(List<ExportItem> items, DateTime exportedAt) => {
      'app': 'bequest',
      'version': 1,
      'exported_at': exportedAt.toIso8601String(),
      'assets': items.map((e) => e.toJson()).toList(growable: false),
    };

/// 解析导出文件文本。顶层结构(app/assets)不符时返回 null。
List<Map<String, dynamic>>? parseExportFile(String text) {
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['app'] != 'bequest') return null;
    final assets = decoded['assets'];
    if (assets is! List) return null;
    return assets.whereType<Map<String, dynamic>>().toList(growable: false);
  } catch (_) {
    return null;
  }
}

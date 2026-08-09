/// 资产。敏感字段(credentials/notes)仅保存在本地内存中,
/// 服务器端只有加密后的 encrypted_data。
class Asset {
  const Asset({
    required this.id,
    required this.name,
    required this.assetType,
    this.categoryId,
    this.expiryDate,
    this.encryptedData,
    this.credentials,
    this.notes,
    this.updatedAt,
  });

  factory Asset.fromJson(Map<String, dynamic> json) => Asset(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        assetType: json['asset_type']?.toString() ?? 'physical',
        categoryId: json['category_id']?.toString(),
        expiryDate: json['expiry_date']?.toString(),
        encryptedData: json['encrypted_data']?.toString(),
        updatedAt: json['updated_at']?.toString(),
      );

  final String id;
  final String name;
  final String assetType; // physical | virtual
  final String? categoryId;
  final String? expiryDate; // YYYY-MM-DD
  final String? encryptedData; // base64,仅完整详情接口返回
  final String? credentials; // 解密后的凭据,仅本地
  final String? notes; // 解密后的备注,仅本地
  final String? updatedAt;

  /// 提交给服务器的请求体。
  Map<String, dynamic> toJson() => {
        'name': name,
        'asset_type': assetType,
        'category_id': categoryId,
        'encrypted_data': encryptedData,
        'expiry_date': expiryDate,
      };
}

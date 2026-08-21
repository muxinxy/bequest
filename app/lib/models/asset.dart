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
    this.status = 'active',
  });

  factory Asset.fromJson(Map<String, dynamic> json) => Asset(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        assetType: json['asset_type']?.toString() ?? 'physical',
        categoryId: json['category_id']?.toString(),
        expiryDate: json['expiry_date']?.toString(),
        encryptedData: json['encrypted_data']?.toString(),
        updatedAt: json['updated_at']?.toString(),
        status: json['status']?.toString() ?? 'active',
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
  final String status; // active | inactive | pending | expired

  /// 序列化。与 [Asset.fromJson] 互为逆:id/updated_at 一并保留,
  /// 否则主页列表经 toJson→fromJson 往返后 id 变为空串,
  /// 编辑页 getAsset('') 会抛 StateError("资产不存在")。
  /// 服务端请求体不依赖本方法(资产编辑页内联构建 body)。
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'asset_type': assetType,
        'category_id': categoryId,
        'encrypted_data': encryptedData,
        'expiry_date': expiryDate,
        'updated_at': updatedAt,
        'status': status,
      };
}

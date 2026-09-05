import 'dart:convert';

import 'package:flutter/material.dart';

import '../crypto/asset_crypto.dart';
import '../crypto/attempt_guard.dart';
import '../crypto/master_password.dart';
import '../logger.dart';
import '../l10n/app_l10n.dart';
import '../models/asset.dart';
import '../models/export_format.dart';
import '../platform/file_share.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';

/// 导出页:验证主密码后经仓储拉取资产详情、解密并构建 JSON,分享/下载。
/// 全程客户端解密,云端只见密文;本地模式同样适用(读本地加密库)。
/// [encrypt] 为 true 时导出文件用主密码 AES 加密(.beq),导入时需主密码解密。
class ExportPage extends StatefulWidget {
  const ExportPage({
    super.key,
    required this.assets,
    required this.repository,
    this.encrypt = false,
  });

  final List<Asset> assets;
  final AssetRepository repository;
  final bool encrypt;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  final _store = SecureStore();

  String _status = L10n.tr('准备导出...');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final password = await showMasterPasswordDialog(context);
    if (password == null) {
      _finish();
      return;
    }
    // 失败限流:连续 5 次错误 → 锁定 60 秒,防暴力尝试。
    if (!mounted) return;
    final guard = AttemptGuard(store: _store, prefix: 'master');
    if (!await guardedVerifyMasterPassword(context, guard, password)) {
      _finish();
      return;
    }
    try {
      final masterKey = await _store.readMasterKey();
      if (masterKey == null) {
        _showError(L10n.tr('未找到主密钥,请重新登录或进入本地模式'));
        _finish();
        return;
      }
      setState(() => _status = L10n.tr('正在导出资产...'));
      final items = await _collectItems(masterKey);
      final exportJson = buildExportJson(items, DateTime.now());
      final now = DateTime.now();
      final stamp = '${now.year}${_pad(now.month)}${_pad(now.day)}'
          '_${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}';
      // 加密导出:用主密码 AES-256-GCM 加密整个 JSON,导入时需主密码解密。
      final content = widget.encrypt
          ? encryptSensitiveData(jsonEncode(exportJson), masterKey)
          : jsonEncode(exportJson);
      final fileName = 'bequest_export_$stamp${widget.encrypt ? '.beq' : '.json'}';
      final ok = await shareTextFile(fileName, content, L10n.tr('托孤资产导出'));
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(ok ? L10n.tr('导出成功') : L10n.tr('导出失败,请检查网络后重试'))));
      _finish();
    } catch (e) {
      Logger.instance.e('export failed: $e');
      _showError(L10n.tr('导出失败,请检查网络后重试'));
      _finish();
    }
  }

  Future<List<ExportItem>> _collectItems(String masterKey) async {
    final categories = await widget.repository.listCategories();
    final categoryNames = <String, String>{
      for (final c in categories)
        if (c['id'] != null && c['name'] != null) '${c['id']}': '${c['name']}',
    };
    final items = <ExportItem>[];
    for (final asset in widget.assets) {
      final full = await widget.repository.getAsset(asset.id);
      String credentials = '';
      String notes = '';
      int? advanceDays;
      final encrypted = full['encrypted_data']?.toString() ?? '';
      if (encrypted.isNotEmpty) {
        try {
          final payload = jsonDecode(decryptAssetData(encrypted, masterKey,
              assetKeyWrappedMk: full['asset_key_wrapped_mk']?.toString()));
          if (payload is Map<String, dynamic>) {
            // 凭据:键值对数组 → "键: 值" 多行文本;旧版纯字符串原样。
            final raw = payload['credentials'];
            if (raw is List) {
              final lines = <String>[];
              for (final item in raw) {
                if (item is Map) {
                  final k = item['key']?.toString() ?? '';
                  final v = item['value']?.toString() ?? '';
                  if (k.isNotEmpty || v.isNotEmpty) lines.add('$k: $v');
                }
              }
              credentials = lines.join('\n');
            } else {
              credentials = raw?.toString() ?? '';
            }
            notes = payload['notes']?.toString() ?? '';
            advanceDays = (payload['advance_days'] as num?)?.toInt();
          }
        } catch (_) {
          // 单条解密失败(密钥不匹配/被篡改):以空凭据导出,不阻断整体。
        }
      }
      final name = asset.categoryId == null
          ? null
          : categoryNames[asset.categoryId];
      items.add(ExportItem(
        name: asset.name,
        assetType: asset.assetType,
        category: (name == null || name.isEmpty) ? null : name,
        expiryDate: asset.expiryDate,
        credentials: credentials,
        notes: notes,
        advanceDays: advanceDays,
      ));
    }
    return items;
  }

  static String _pad(int value) => value.toString().padLeft(2, '0');

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _finish() {
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.tr('导出资产'))),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_status),
          ],
        ),
      ),
    );
  }
}

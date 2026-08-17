import 'dart:convert';

import 'package:flutter/material.dart';

import '../crypto/asset_crypto.dart';
import '../crypto/attempt_guard.dart';
import '../crypto/master_password.dart';
import '../logger.dart';
import '../models/asset.dart';
import '../models/export_format.dart';
import '../platform/file_share.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';
import 'excel_export.dart';

/// Excel 导出页(会员权益):验证主密码后解密资产,生成 .xlsx 分享。
class ExcelExportPage extends StatefulWidget {
  const ExcelExportPage({super.key, required this.assets, required this.repository});

  final List<Asset> assets;
  final AssetRepository repository;

  @override
  State<ExcelExportPage> createState() => _ExcelExportPageState();
}

class _ExcelExportPageState extends State<ExcelExportPage> {
  final _store = SecureStore();
  String _status = '准备导出...';

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
    if (!mounted) return;
    final guard = AttemptGuard(store: _store, prefix: 'master');
    if (!await guardedVerifyMasterPassword(context, guard, password)) {
      _finish();
      return;
    }
    try {
      final masterKey = await _store.readMasterKey();
      if (masterKey == null) {
        _showError('未找到主密钥,请重新登录或进入本地模式');
        _finish();
        return;
      }
      setState(() => _status = '正在生成 Excel...');
      final items = await _collectItems(masterKey);
      final bytes = buildExcelBytes(items);
      final now = DateTime.now();
      String pad(int n) => n.toString().padLeft(2, '0');
      final stamp = '${now.year}${pad(now.month)}${pad(now.day)}'
          '_${pad(now.hour)}${pad(now.minute)}${pad(now.second)}';
      final ok = await shareBytesFile(
        'bequest_export_$stamp.xlsx',
        bytes,
        '托孤资产导出(Excel)',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '导出成功' : '导出失败,请检查网络后重试')),
      );
      _finish();
    } catch (e) {
      Logger.instance.e('excel export failed: $e');
      _showError('导出失败,请检查网络后重试');
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
      // 继承人名称列表(云端;本地模式无继承返回空)。
      var inheritors = <String>[];
      try {
        final binds = await widget.repository.listAssetInheritors(asset.id);
        inheritors = [
          for (final b in binds)
            if (b['inheritor_name'] != null) b['inheritor_name'].toString(),
        ];
      } catch (_) {
        inheritors = [];
      }
      final encrypted = full['encrypted_data']?.toString() ?? '';
      if (encrypted.isNotEmpty) {
        try {
          final payload = jsonDecode(decryptAssetData(encrypted, masterKey,
              assetKeyWrappedMk: full['asset_key_wrapped_mk']?.toString()));
          if (payload is Map<String, dynamic>) {
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
          // 单条解密失败:以空凭据导出,不阻断整体。
        }
      }
      final name = asset.categoryId == null ? null : categoryNames[asset.categoryId];
      items.add(ExportItem(
        name: asset.name,
        assetType: asset.assetType,
        category: (name == null || name.isEmpty) ? null : name,
        expiryDate: asset.expiryDate,
        credentials: credentials,
        notes: notes,
        advanceDays: advanceDays,
        inheritors: inheritors,
      ));
    }
    return items;
  }

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
      appBar: AppBar(title: const Text('导出 Excel')),
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

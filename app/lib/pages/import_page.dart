import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../crypto/asset_crypto.dart';
import '../crypto/master_password.dart';
import '../models/export_format.dart';
import '../models/preset_categories.dart';
import '../storage/secure_store.dart';

/// 导入页:验证主密码后解析导出文件,逐条创建资产并显示进度。
/// 导入文件为用户提供,逐条做防御性校验,失败项计入失败数。
class ImportPage extends StatefulWidget {
  const ImportPage({super.key, required this.fileText});

  final String fileText;

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  final _api = ApiClient();
  final _store = SecureStore();

  String _status = '准备导入...';

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
    if (!await verifyMasterPassword(password)) {
      _showError('主密码错误');
      _finish();
      return;
    }
    final items = parseExportFile(widget.fileText);
    if (items == null) {
      _showError('无效的导出文件');
      _finish();
      return;
    }
    try {
      final jwt = await _store.readJwt();
      final masterKey = await _store.readMasterKey();
      if (jwt == null || masterKey == null) {
        _showError('登录状态已失效,请重新登录');
        _finish();
        return;
      }
      final categoryNames = <String, String>{
        for (final c in await _api.listCategories(jwt))
          if (c['name'] != null && c['id'] != null) '${c['name']}': '${c['id']}',
      };
      var success = 0;
      var failed = 0;
      for (var i = 0; i < items.length; i++) {
        if (!mounted) return;
        setState(() => _status = '导入中 ${i + 1}/${items.length}');
        try {
          await _createOne(jwt, masterKey, items[i], categoryNames);
          success++;
        } catch (_) {
          failed++;
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入完成: 成功 $success 条,失败 $failed 条')),
      );
      _finish();
    } catch (_) {
      _showError('导入失败,请检查网络后重试');
      _finish();
    }
  }

  Future<void> _createOne(
    String jwt,
    String masterKey,
    Map<String, dynamic> item,
    Map<String, String> categoryNames,
  ) async {
    final name = item['name']?.toString().trim() ?? '';
    final assetType = item['asset_type']?.toString();
    if (name.isEmpty || (assetType != 'physical' && assetType != 'virtual')) {
      // 导入文件是用户提供的信任边界:缺名称/类型按失败计。
      throw const FormatException('缺少名称或类型');
    }
    final categoryId = await _resolveCategoryId(jwt, item, categoryNames);
    final payload = <String, dynamic>{
      'credentials': item['credentials']?.toString() ?? '',
      'notes': item['notes']?.toString() ?? '',
    };
    final advanceDays = (item['advance_days'] as num?)?.toInt();
    if (advanceDays != null) payload['advance_days'] = advanceDays;
    final expiry = item['expiry_date']?.toString().trim() ?? '';
    await _api.createAsset(jwt, {
      'name': name,
      'asset_type': assetType,
      'category_id': categoryId,
      'encrypted_data': encryptSensitiveData(jsonEncode(payload), masterKey),
      'expiry_date': expiry.isEmpty ? null : expiry,
    });
  }

  /// 分类名 → 服务器分类 id;预设分类无服务器 id,与 P1 决策一致返回 null。
  Future<String?> _resolveCategoryId(
    String jwt,
    Map<String, dynamic> item,
    Map<String, String> categoryNames,
  ) async {
    final category = item['category']?.toString().trim() ?? '';
    if (category.isEmpty) return null;
    if (kPhysicalPresetCategories.contains(category) ||
        kVirtualPresetCategories.contains(category)) {
      return null;
    }
    final existingId = categoryNames[category];
    if (existingId != null) return existingId;
    final created = await _api.createCategory(jwt, category);
    final newId = created['id']?.toString();
    if (newId != null && newId.isNotEmpty) categoryNames[category] = newId;
    return newId;
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
      appBar: AppBar(title: const Text('导入资产')),
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

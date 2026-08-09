import 'dart:convert';

import 'package:flutter/material.dart';

import '../crypto/asset_crypto.dart';
import '../crypto/master_password.dart';
import '../models/export_format.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';
import 'local_unlock_page.dart';

/// 导入页:验证主密码后解析导出文件,经仓储逐条创建资产并显示进度。
/// 云端模式写入服务器;本地模式写入本地加密库(jwt 为空时)。
class ImportPage extends StatefulWidget {
  const ImportPage({super.key, required this.fileText, required this.repository});

  final String fileText;
  final AssetRepository repository;

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
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
    final salt = await _store.readMasterSalt();
    if (salt == null || salt.isEmpty) {
      // 本机无盐:无法校验主密码,引导走与本地模式一致的设置主密码流程。
      await _guideSetMasterPassword();
      _finish();
      return;
    }
    if (!await verifyMasterPassword(password)) {
      _showError('主密码错误');
      _finish();
      return;
    }
    final masterKey = await _store.readMasterKey();
    if (masterKey == null) {
      _showError('未找到主密钥,请重新登录或进入本地模式');
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
      final categoryNames = <String, String>{
        for (final c in await widget.repository.listCategories())
          if (c['name'] != null && c['id'] != null) '${c['name']}': '${c['id']}',
      };
      var success = 0;
      var failed = 0;
      for (var i = 0; i < items.length; i++) {
        if (!mounted) return;
        setState(() => _status = '导入中 ${i + 1}/${items.length}');
        try {
          await _createOne(masterKey, items[i], categoryNames);
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

  /// 引导设置主密码(与本地模式相同的流程),设置后用户可重新进入导入。
  Future<void> _guideSetMasterPassword() async {
    if (!mounted) return;
    final goSetup = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('未设置主密码'),
        content: const Text('导入资产需要主密码。是否前往设置主密码?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (goSetup == true && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const LocalUnlockPage()),
      );
    }
  }

  Future<void> _createOne(
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
    final categoryId = await _resolveCategoryId(item, categoryNames);
    final payload = <String, dynamic>{
      'credentials': item['credentials']?.toString() ?? '',
      'notes': item['notes']?.toString() ?? '',
    };
    final advanceDays = (item['advance_days'] as num?)?.toInt();
    if (advanceDays != null) payload['advance_days'] = advanceDays;
    final expiry = item['expiry_date']?.toString().trim() ?? '';
    await widget.repository.createAsset({
      'name': name,
      'asset_type': assetType,
      'category_id': categoryId,
      'encrypted_data': encryptSensitiveData(jsonEncode(payload), masterKey),
      'expiry_date': expiry.isEmpty ? null : expiry,
    });
  }

  /// 分类名 → 仓储分类 id;已存在(预设或自定义)复用,否则按名创建。
  Future<String?> _resolveCategoryId(
    Map<String, dynamic> item,
    Map<String, String> categoryNames,
  ) async {
    final category = item['category']?.toString().trim() ?? '';
    if (category.isEmpty) return null;
    final existingId = categoryNames[category];
    if (existingId != null) return existingId;
    final created = await widget.repository.createCategory(
      category,
      assetType: item['asset_type']?.toString() ?? 'physical',
    );
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

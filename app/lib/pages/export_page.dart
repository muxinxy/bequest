import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../crypto/asset_crypto.dart';
import '../crypto/master_password.dart';
import '../models/asset.dart';
import '../models/export_format.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';

/// 导出页:验证主密码后经仓储拉取资产详情、解密并构建 JSON,写入临时文件分享。
/// 全程客户端解密,云端只见密文;本地模式同样适用(读本地加密库)。
class ExportPage extends StatefulWidget {
  const ExportPage({super.key, required this.assets, required this.repository});

  final List<Asset> assets;
  final AssetRepository repository;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
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
    if (!await verifyMasterPassword(password)) {
      _showError('主密码错误');
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
      setState(() => _status = '正在导出资产...');
      final items = await _collectItems(masterKey);
      final exportJson = buildExportJson(items, DateTime.now());
      final file = await _writeTempFile(exportJson);
      // 分享面板失败不影响导出文件已生成;测试环境无原生实现,忽略异常。
      try {
        await SharePlus.instance.share(
          ShareParams(files: [XFile(file.path)], text: '托孤资产导出'),
        );
      } catch (_) {
        // 分享不可用时忽略,文件仍在临时目录。
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('导出成功')));
      _finish();
    } catch (_) {
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
      final encrypted = full['encrypted_data']?.toString() ?? '';
      if (encrypted.isNotEmpty) {
        try {
          final payload =
              jsonDecode(decryptSensitiveData(encrypted, masterKey));
          if (payload is Map<String, dynamic>) {
            credentials = payload['credentials']?.toString() ?? '';
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

  Future<File> _writeTempFile(Map<String, dynamic> exportJson) async {
    final dir = await getTemporaryDirectory();
    final now = DateTime.now();
    final name = 'bequest_export_'
        '${now.year}${_pad(now.month)}${_pad(now.day)}'
        '_${_pad(now.hour)}${_pad(now.minute)}${_pad(now.second)}.json';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(jsonEncode(exportJson));
    return file;
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
      appBar: AppBar(title: const Text('导出资产')),
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

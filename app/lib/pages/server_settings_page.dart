import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api/api_config.dart';
import '../models/preset_categories.dart';
import '../repository/cloud_asset_repository.dart';
import '../repository/local_asset_repository.dart';
import '../storage/secure_store.dart';
import '../storage/storage_mode.dart';
import '../sync/local_vault.dart';

/// 服务器设置:可配置服务器地址(立即生效)与存储模式(云端/本地,切换时迁移数据)。
class ServerSettingsPage extends StatefulWidget {
  const ServerSettingsPage({super.key});

  @override
  State<ServerSettingsPage> createState() => _ServerSettingsPageState();
}

class _ServerSettingsPageState extends State<ServerSettingsPage> {
  final _store = SecureStore();
  final _urlController = TextEditingController();

  StorageMode _mode = StorageMode.cloud;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final url = await ApiConfig.baseUrl();
    final mode = await _store.readStorageMode();
    if (!mounted) return;
    setState(() {
      _urlController.text = url;
      _mode = mode == 'local' ? StorageMode.local : StorageMode.cloud;
    });
  }

  Future<void> _saveUrl() async {
    final url = _urlController.text.trim().replaceFirst(RegExp(r'/+$'), '');
    if (url.isEmpty) {
      _snack('请输入服务器地址');
      return;
    }
    await ApiConfig.setBaseUrl(url);
    _snack('已保存');
  }

  Future<void> _testConnection() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _snack('请输入服务器地址');
      return;
    }
    setState(() => _busy = true);
    try {
      final res = await http
          .get(Uri.parse('$url/api/v1/version'))
          .timeout(const Duration(seconds: 5));
      _snack(
        res.statusCode >= 200 && res.statusCode < 300
            ? '连接成功'
            : '连接失败(${res.statusCode})',
      );
    } catch (_) {
      _snack('连接失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switchMode(StorageMode next) async {
    if (next == _mode || _busy) return;
    setState(() => _busy = true);
    try {
      final ok = next == StorageMode.local
          ? await _migrateCloudToLocal()
          : await _migrateLocalToCloud();
      if (ok && mounted) setState(() => _mode = next);
    } catch (_) {
      if (mounted) _snack('切换失败,请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 云端 → 本地:拉取云端全量数据(资产含密文)写入本地加密库。
  /// ponytail: 迁移是切换时一次性拷贝,非持续同步;冲突以云端为准。
  Future<bool> _migrateCloudToLocal() async {
    final jwt = await _store.readJwt();
    final mk = await _store.readMasterKey();
    if (jwt == null || mk == null || mk.isEmpty) {
      _snack('请先登录并设置主密码,再切换到本地模式');
      return false;
    }
    _snack('正在拉取云端数据...');
    final cloud = await CloudAssetRepository.create(jwt: jwt);
    final assets = await cloud.listAssets();
    final fullAssets = <Map<String, dynamic>>[];
    for (final asset in assets) {
      try {
        fullAssets.add(await cloud.getAsset('${asset['id']}'));
      } catch (_) {
        // 单条失败跳过,不阻断迁移。
      }
    }
    final categories = await cloud.listCategories();
    final vault = LocalVault();
    final salt = await _store.readMasterSalt() ?? await vault.readSalt(mk);
    await vault.saveLocalData(
      {'schema': 1, 'assets': fullAssets, 'categories': categories},
      mk,
      salt: salt,
    );
    await _store.saveStorageMode('local');
    _snack('已切换到本地模式,数据已备份到本机');
    return true;
  }

  /// 本地 → 云端:本地数据逐条上传;分类按名去重,资产分类 id 按名映射。
  /// ponytail: 一次性拷贝迁移;后续变更需再次切换或使用同步功能。
  Future<bool> _migrateLocalToCloud() async {
    final jwt = await _store.readJwt();
    if (jwt == null) {
      _snack('请先登录再切换到云端');
      return false;
    }
    final mk = await _store.readMasterKey();
    if (mk == null || mk.isEmpty) {
      _snack('未找到主密钥,无法读取本地数据');
      return false;
    }
    _snack('正在上传本地数据...');
    final local = LocalAssetRepository(masterKeyB64: mk);
    final cloud = await CloudAssetRepository.create(jwt: jwt);
    // 分类:按名去重,已存在则跳过;预设分类不上传(服务端无对应分类)。
    final presetNames = <String>{
      ...kPhysicalPresetCategories,
      ...kVirtualPresetCategories,
    };
    final serverCatIdByName = <String, String>{
      for (final c in await cloud.listCategories())
        if (c['name'] != null && c['id'] != null) '${c['name']}': '${c['id']}',
    };
    for (final c in await local.listCategories()) {
      final name = c['name']?.toString() ?? '';
      if (name.isEmpty || presetNames.contains(name)) continue;
      if (serverCatIdByName.containsKey(name)) continue;
      final created = await cloud.createCategory(name);
      serverCatIdByName[name] = '${created['id']}';
    }
    // 资产:原样上传,本地分类 id 按名字映射到服务端(预设/未分类 → null)。
    final localCatNameById = <String, String>{
      for (final c in await local.listCategories())
        if (c['id'] != null && c['name'] != null) '${c['id']}': '${c['name']}',
    };
    var ok = 0;
    var fail = 0;
    for (final a in await local.listAssets()) {
      try {
        final full = await local.getAsset('${a['id']}');
        final catId = full['category_id']?.toString();
        String? mappedId;
        if (catId != null && catId.isNotEmpty) {
          final name = localCatNameById[catId];
          if (name != null && !presetNames.contains(name)) {
            mappedId = serverCatIdByName[name];
          }
        }
        await cloud.createAsset({
          'name': full['name']?.toString() ?? '',
          'asset_type': full['asset_type']?.toString() ?? 'physical',
          'category_id': mappedId,
          'encrypted_data': full['encrypted_data']?.toString() ?? '',
          'expiry_date': full['expiry_date']?.toString(),
        });
        ok++;
      } catch (_) {
        fail++;
      }
    }
    await _store.saveStorageMode('cloud');
    _snack('已切换到云端模式,本地数据已上传(成功 $ok 失败 $fail)');
    return true;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务器设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('服务器地址', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextFormField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: 'http://10.0.2.2:8080',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _saveUrl,
                  child: const Text('保存'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _testConnection,
                  child: const Text('测试连接'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          const Text('存储模式', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text(
            '切换时会将数据迁移到目标存储(一次性拷贝,非持续同步)。',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          SegmentedButton<StorageMode>(
            segments: const [
              ButtonSegment(
                value: StorageMode.cloud,
                label: Text('云端'),
                icon: Icon(Icons.cloud_outlined),
              ),
              ButtonSegment(
                value: StorageMode.local,
                label: Text('本地'),
                icon: Icon(Icons.phone_android),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (selection) => _switchMode(selection.first),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }
}

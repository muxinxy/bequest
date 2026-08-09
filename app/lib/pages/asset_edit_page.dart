import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../crypto/asset_crypto.dart';
import '../models/asset.dart';
import '../models/category.dart';
import '../models/preset_categories.dart';
import '../storage/secure_store.dart';

/// 资产编辑页:新建(asset 为 null)或编辑(asset 非空)。
/// 凭据与备注用主密钥加密后提交服务器。
class AssetEditPage extends StatefulWidget {
  const AssetEditPage({super.key, this.asset});

  final Asset? asset;

  @override
  State<AssetEditPage> createState() => _AssetEditPageState();
}

class _AssetEditPageState extends State<AssetEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _api = ApiClient();
  final _store = SecureStore();

  final _nameController = TextEditingController();
  final _credentialsController = TextEditingController();
  final _notesController = TextEditingController();

  String _assetType = 'physical';
  List<Category> _categories = const [];

  /// 分类下拉值:'' = 未分类,'preset:名称' = 预设分类,其他 = 自定义分类 id。
  String _categoryValue = '';
  String? _expiryDate;

  bool _loading = true;
  bool _saving = false;
  bool _decryptFailed = false;
  bool get _isEdit => widget.asset != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _credentialsController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) {
        throw ApiException('未登录');
      }
      final categories = (await _api.listCategories(jwt))
          .map(Category.fromJson)
          .toList(growable: false);
      if (_isEdit) {
        final full = await _api.getAsset(jwt, widget.asset!.id);
        final asset = Asset.fromJson(full);
        String? credentials;
        String? notes;
        final encrypted = asset.encryptedData;
        if (encrypted != null && encrypted.isNotEmpty) {
          try {
            final masterKey = await _store.readMasterKey();
            if (masterKey != null) {
              final payload =
                  jsonDecode(decryptSensitiveData(encrypted, masterKey));
              if (payload is Map<String, dynamic>) {
                credentials = payload['credentials']?.toString();
                notes = payload['notes']?.toString();
              }
            }
          } catch (_) {
            _decryptFailed = true;
          }
        }
        if (!mounted) return;
        setState(() {
          _assetType = asset.assetType;
          _expiryDate = asset.expiryDate;
          _categoryValue = categories.any((c) => c.id == asset.categoryId)
              ? (asset.categoryId ?? '')
              : '';
          _nameController.text = asset.name;
          _credentialsController.text = credentials ?? '';
          _notesController.text = notes ?? '';
          _categories = categories;
          _loading = false;
        });
        if (_decryptFailed) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('敏感信息解密失败,可能已被篡改或密钥不匹配,请重新填写保存'),
            ),
          );
        }
      } else {
        if (!mounted) return;
        setState(() {
          _categories = categories;
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  Future<void> _pickExpiryDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _parseDate(_expiryDate) ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _expiryDate = _formatDate(picked));
  }

  static DateTime? _parseDate(String? value) {
    if (value == null) return null;
    return DateTime.tryParse(value);
  }

  static String _formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String? _categoryIdToSubmit() {
    final value = _categoryValue;
    if (value.isEmpty || value.startsWith('preset:')) return null;
    return value;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final jwt = await _store.readJwt();
      final masterKey = await _store.readMasterKey();
      if (jwt == null || masterKey == null) {
        throw ApiException('登录状态已失效,请重新登录');
      }
      final payload = jsonEncode({
        'credentials': _credentialsController.text.trim(),
        'notes': _notesController.text.trim(),
      });
      final body = {
        'name': _nameController.text.trim(),
        'asset_type': _assetType,
        'category_id': _categoryIdToSubmit(),
        'encrypted_data': encryptSensitiveData(payload, masterKey),
        'expiry_date': _expiryDate,
      };
      if (_isEdit) {
        await _api.updateAsset(jwt, widget.asset!.id, body);
      } else {
        await _api.createAsset(jwt, body);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_isEdit ? '已保存' : '已添加')));
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('保存失败,请检查网络后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? '编辑资产' : '添加资产')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: '名称 *',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          (value == null || value.trim().isEmpty) ? '请输入名称' : null,
                    ),
                    const SizedBox(height: 16),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'physical',
                          label: Text('实体'),
                          icon: Icon(Icons.inventory_2_outlined),
                        ),
                        ButtonSegment(
                          value: 'virtual',
                          label: Text('虚拟'),
                          icon: Icon(Icons.cloud_outlined),
                        ),
                      ],
                      selected: {_assetType},
                      onSelectionChanged: (selection) => setState(() {
                        if (_categoryValue.startsWith('preset:')) {
                          _categoryValue = '';
                        }
                        _assetType = selection.first;
                      }),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: ValueKey('category-$_assetType'),
                      initialValue: _categoryValue,
                      decoration: const InputDecoration(
                        labelText: '分类',
                        border: OutlineInputBorder(),
                      ),
                      items: _categoryItems(),
                      onChanged: (value) =>
                          setState(() => _categoryValue = value ?? ''),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _credentialsController,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: '凭据',
                        hintText: '账号、密码、密钥等,加密保存',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _notesController,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        labelText: '备注',
                        hintText: '补充说明,加密保存',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('到期日'),
                      subtitle: Text(_expiryDate ?? '未设置(可选)'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '选择日期',
                            icon: const Icon(Icons.calendar_month),
                            onPressed: _pickExpiryDate,
                          ),
                          if (_expiryDate != null)
                            IconButton(
                              tooltip: '清除日期',
                              icon: const Icon(Icons.clear),
                              onPressed: () =>
                                  setState(() => _expiryDate = null),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('保存'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  List<DropdownMenuItem<String>> _categoryItems() {
    return [
      const DropdownMenuItem(value: '', child: Text('未分类')),
      ...presetCategoriesFor(_assetType)
          .map((n) => DropdownMenuItem(value: 'preset:$n', child: Text(n))),
      ..._categories.map(
        (c) => DropdownMenuItem(value: c.id, child: Text(c.name)),
      ),
    ];
  }
}

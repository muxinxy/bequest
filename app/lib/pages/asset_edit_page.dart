import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../crypto/asset_crypto.dart';
import '../models/asset.dart';
import '../models/category.dart';
import '../models/entitlements.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';

/// 资产编辑页:新建(asset 为 null)或编辑(asset 非空)。
/// 凭据与备注用主密钥加密后经仓储写入(云端或本地库)。
class AssetEditPage extends StatefulWidget {
  const AssetEditPage({super.key, this.asset, required this.repository});

  final Asset? asset;
  final AssetRepository repository;

  @override
  State<AssetEditPage> createState() => _AssetEditPageState();
}

class _AssetEditPageState extends State<AssetEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _store = SecureStore();

  final _nameController = TextEditingController();
  final _credentialsController = TextEditingController();
  final _notesController = TextEditingController();

  String _assetType = 'physical';
  List<Category> _categories = const [];

  /// 分类下拉值:'' = 未分类,其他 = 分类 id(预设与自定义同表)。
  String _categoryValue = '';
  String? _expiryDate;

  /// 到期提醒提前天数:null = 不提醒,0 = 到期当天。
  int? _advanceDays;

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
      final categories = (await widget.repository.listCategories())
          .map(Category.fromJson)
          .toList(growable: false);
      if (_isEdit) {
        final full = await widget.repository.getAsset(widget.asset!.id);
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
                _advanceDays = (payload['advance_days'] as num?)?.toInt();
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
    if (value.isEmpty) return null;
    return value;
  }

  Future<void> _deleteAsset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除资产'),
        content: const Text('确定删除该资产?此操作不可恢复'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.repository.deleteAsset(widget.asset!.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已删除')));
      Navigator.of(context).pop();
    } catch (_) {
      _showError('删除失败,请检查网络后重试');
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_isEdit) {
      // 权益上限:新建时校验(访客 20 / 免费用户 50,会员不限)。
      final jwt = await _store.readJwt();
      final ent = Entitlements.forJwtAndTier(hasJwt: jwt != null, tier: null);
      final limit = ent.assetLimit;
      if (limit != null) {
        final count = (await widget.repository.listAssets()).length;
        if (count >= limit) {
          _showError('已达资产上限 $limit 条,升级会员可解锁');
          return;
        }
      }
    }
    setState(() => _saving = true);
    try {
      final masterKey = await _store.readMasterKey();
      if (masterKey == null) {
        throw ApiException('未找到主密钥,请重新登录或进入本地模式');
      }
      final payload = <String, dynamic>{
        'credentials': _credentialsController.text.trim(),
        'notes': _notesController.text.trim(),
      };
      // ponytail: 后端资产接口暂无 reminder_settings 字段,
      // 提前天数先随加密载荷往返,待 API 支持后再挪到独立字段。
      if (_advanceDays != null) payload['advance_days'] = _advanceDays;
      final body = {
        'name': _nameController.text.trim(),
        'asset_type': _assetType,
        'category_id': _categoryIdToSubmit(),
        'encrypted_data': encryptSensitiveData(jsonEncode(payload), masterKey),
        'expiry_date': _expiryDate,
      };
      if (_isEdit) {
        await widget.repository.updateAsset(widget.asset!.id, body);
      } else {
        await widget.repository.createAsset(body);
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
      appBar: AppBar(
        title: Text(_isEdit ? '编辑资产' : '添加资产'),
        actions: [
          if (_isEdit)
            IconButton(
              tooltip: '删除资产',
              icon: const Icon(Icons.delete_outline),
              onPressed: _deleteAsset,
            ),
        ],
      ),
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
                        final next = selection.first;
                        // 切换类型后,原分类类型不匹配则回到未分类。
                        if (_categoryValue.isNotEmpty &&
                            !_categories.any((c) =>
                                c.id == _categoryValue &&
                                c.assetType == next)) {
                          _categoryValue = '';
                        }
                        _assetType = next;
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
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int?>(
                      key: const ValueKey('advance-days'),
                      initialValue: _advanceDays,
                      decoration: const InputDecoration(
                        labelText: '到期提醒提前天数',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem<int?>(value: null, child: Text('不提醒')),
                        DropdownMenuItem<int?>(value: 30, child: Text('提前30天')),
                        DropdownMenuItem<int?>(value: 7, child: Text('提前7天')),
                        DropdownMenuItem<int?>(value: 1, child: Text('提前1天')),
                        DropdownMenuItem<int?>(value: 0, child: Text('到期当天')),
                      ],
                      onChanged: (value) =>
                          setState(() => _advanceDays = value),
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
    // 只展示与当前资产类型匹配的分类(预设与自定义同表)。
    final matches = _categories
        .where((c) => c.assetType == _assetType)
        .toList(growable: false);
    return [
      const DropdownMenuItem(value: '', child: Text('未分类')),
      ...matches.map(
        (c) => DropdownMenuItem(
          value: c.id,
          child: Text(c.isPreset ? '${c.name}(预设)' : c.name),
        ),
      ),
    ];
  }
}

import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../crypto/asset_crypto.dart';
import '../models/asset.dart';
import '../models/category.dart';
import '../models/entitlements.dart';
import '../repository/asset_repository.dart';
import '../repository/local_asset_repository.dart';
import '../storage/secure_store.dart';
import 'asset_inheritors_page.dart';
import 'login_page.dart';

/// 资产编辑页:新建(asset 为 null)或编辑(asset 非空)。
/// 凭据与备注用主密钥加密后经仓储写入(云端或本地库)。
/// tier 为云端权益层级(free/member),本地模式传 null(访客权益)。
class AssetEditPage extends StatefulWidget {
  const AssetEditPage({super.key, this.asset, required this.repository, this.tier});

  final Asset? asset;
  final AssetRepository repository;
  final String? tier;

  @override
  State<AssetEditPage> createState() => _AssetEditPageState();
}

class _AssetEditPageState extends State<AssetEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _store = SecureStore();

  final _nameController = TextEditingController();
  final _notesController = TextEditingController();

  /// 凭据键值对:每项 [key, value] 控制器,可增删。
  final List<({TextEditingController key, TextEditingController value})>
      _credentialFields = [];
  static const _credentialSuggestions = ['账号', '密码', '邮箱', '密钥', '恢复码', '验证码'];

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

  /// 云端资产的资产密钥包装(编辑时解出原 AK 复用,保持密钥稳定)。
  String? _assetKeyWrappedMk;

  /// 本地模式(注入的是 LocalAssetRepository)下失败与网络无关,提示语要准确。
  bool get _isLocalRepo => widget.repository is LocalAssetRepository;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final f in _credentialFields) {
      f.key.dispose();
      f.value.dispose();
    }
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
        String? notes;
        final encrypted = asset.encryptedData;
        _assetKeyWrappedMk = full['asset_key_wrapped_mk']?.toString();
        if (encrypted != null && encrypted.isNotEmpty) {
          try {
            final masterKey = await _store.readMasterKey();
            if (masterKey != null) {
              // 资产级密钥隔离:有 asset_key_wrapped_mk 时解出 AK 再解密;
              // 老资产(无包装)回退直接用主密钥解密。
              String key = masterKey;
              final wrappedMk = _assetKeyWrappedMk;
              if (wrappedMk != null && wrappedMk.isNotEmpty) {
                key = unwrapAssetKey(wrappedMk, masterKey);
              }
              final payload =
                  jsonDecode(decryptSensitiveData(encrypted, key));
              if (payload is Map<String, dynamic>) {
                notes = payload['notes']?.toString();
                _advanceDays = (payload['advance_days'] as num?)?.toInt();
                // 凭据:新版为键值对数组 [{key,value}],旧版为纯字符串
                // (当作单行"凭据"键值对,渐进兼容)。
                final rawCred = payload['credentials'];
                if (rawCred is List) {
                  for (final item in rawCred) {
                    if (item is Map) {
                      _credentialFields.add((
                        key: TextEditingController(text: item['key']?.toString() ?? ''),
                        value: TextEditingController(text: item['value']?.toString() ?? ''),
                      ));
                    }
                  }
                } else {
                  final s = rawCred?.toString() ?? '';
                  if (s.isNotEmpty) {
                    _credentialFields.add((
                      key: TextEditingController(text: '凭据'),
                      value: TextEditingController(text: s),
                    ));
                  }
                }
              }
            }
          } catch (_) {
            _decryptFailed = true;
          }
        }
        if (!mounted) return;
        setState(() {
          _expiryDate = asset.expiryDate;
          _categoryValue = categories.any((c) => c.id == asset.categoryId)
              ? (asset.categoryId ?? '')
              : '';
          _nameController.text = asset.name;
          _notesController.text = notes ?? '';
          _categories = categories;
          _loading = false;
        });
        if (_decryptFailed) {
          if (_isLocalRepo) {
            // 本地库解密失败与多端无关(本地数据/篡改),保留原提示。
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('敏感信息解密失败,可能已被篡改或密钥不匹配,请重新填写保存'),
              ),
            );
          } else {
            // 云端解密失败最常见原因是主密码在其他设备已修改(多端不一致):
            // 本机主密钥已失效,提示重新登录恢复。
            await _promptRelogin();
          }
        }
      } else {
        if (!mounted) return;
        setState(() {
          _categories = categories;
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final message = _isLocalRepo
          ? (e is StateError ? '资产不存在或本地数据异常' : '加载失败,本地数据读取异常')
          : '加载失败,请检查网络后重试';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      Navigator.of(context).pop();
    }
  }

  /// 云端敏感信息解密失败:极可能是主密码已在其他设备修改(多端不一致),
  /// 本机主密钥已失效。提示退出重新登录(登录后走恢复流程重派生密钥)。
  Future<void> _promptRelogin() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('无法解密敏感信息'),
        content: const Text(
          '主密码可能已在其他设备修改,本机加密密钥已失效。请退出登录并重新登录以恢复密钥。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _store.clearAll();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
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

  /// 分类 id 提交值:
  /// - 云端:数字(服务端 assetRequest.CategoryID 为 int64,字符串会 400 invalid JSON);
  /// - 本地:'L<时间戳><序号>' 字符串,原样保留。
  Object? _categoryIdToSubmit() {
    final value = _categoryValue;
    if (value.isEmpty) return null;
    if (_isLocalRepo) return value;
    return int.tryParse(value);
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
      _showError(_isLocalRepo ? '删除失败,请重试' : '删除失败,请检查网络后重试');
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_isEdit) {
      // 权益上限:新建时校验(访客 20 / 免费用户 50,会员不限)。
      final jwt = await _store.readJwt();
      final ent = Entitlements.forJwtAndTier(hasJwt: jwt != null, tier: widget.tier);
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
        // 凭据键值对:非空对组成数组;空列表(全新)不写 credentials 字段。
        'credentials': [
          for (final f in _credentialFields)
            if (f.key.text.trim().isNotEmpty || f.value.text.trim().isNotEmpty)
              {'key': f.key.text.trim(), 'value': f.value.text.trim()},
        ],
        'notes': _notesController.text.trim(),
      };
      // 没有任何键值对时省略 credentials(与旧数据空凭据一致)。
      if ((payload['credentials'] as List).isEmpty) payload.remove('credentials');
      // ponytail: 后端资产接口暂无 reminder_settings 字段,
      // 提前天数先随加密载荷往返,待 API 支持后再挪到独立字段。
      if (_advanceDays != null) payload['advance_days'] = _advanceDays;
      final body = <String, dynamic>{
        'name': _nameController.text.trim(),
        // 兼容保留:UI 不再区分实体/虚拟,统一按后端默认 physical 提交。
        'asset_type': 'physical',
        'category_id': _categoryIdToSubmit(),
        'expiry_date': _expiryDate,
      };
      if (_isLocalRepo) {
        // 本地模式:无继承,直接用主密钥加密(与旧数据一致,渐进兼容)。
        body['encrypted_data'] = encryptSensitiveData(jsonEncode(payload), masterKey);
      } else {
        // 云端模式:资产级密钥隔离——内容用独立 AK 加密,AK 分别被 MK(号主)
        // 与 WK(继承人)包装上传。编辑时若已有 AK 则解出复用,保持稳定。
        String assetKey;
        final existingWrappedMk = _assetKeyWrappedMk;
        if (_isEdit && existingWrappedMk != null && existingWrappedMk.isNotEmpty) {
          try {
            assetKey = unwrapAssetKey(existingWrappedMk, masterKey);
          } catch (_) {
            assetKey = generateAssetKey();
          }
        } else {
          assetKey = generateAssetKey();
        }
        final wrappingKey = await _store.readWrappingKey();
        if (wrappingKey == null || wrappingKey.isEmpty) {
          throw ApiException('未找到继承包装密钥,请重新登录');
        }
        body['encrypted_data'] = encryptSensitiveData(jsonEncode(payload), assetKey);
        body['asset_key_wrapped_mk'] = wrapAssetKey(assetKey, masterKey);
        body['asset_key_wrapped_wk'] = wrapAssetKey(assetKey, wrappingKey);
      }
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
      _showError(_isLocalRepo ? '保存失败,请重试' : '保存失败,请检查网络后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _addCredentialField() {
    setState(() {
      _credentialFields.add((
        key: TextEditingController(),
        value: TextEditingController(),
      ));
    });
  }

  void _removeCredentialField(int index) {
    final f = _credentialFields.removeAt(index);
    f.key.dispose();
    f.value.dispose();
    setState(() {});
  }

  /// 单行键值对:键(带常用提示)+ 值 + 删除按钮。
  Widget _credentialRow(int index) {
    final f = _credentialFields[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Autocomplete<String>(
              initialValue: TextEditingValue(text: f.key.text),
              optionsBuilder: (TextEditingValue editing) {
                if (editing.text.isEmpty) return const Iterable<String>.empty();
                return _credentialSuggestions.where(
                  (s) => s.contains(editing.text) || editing.text.contains(s),
                );
              },
              onSelected: (s) => f.key.text = s,
              fieldViewBuilder: (context, controller, focusNode, onSubmit) {
                // Autocomplete 用内部 controller 同步外部值。
                controller.text = f.key.text;
                controller.selection =
                    TextSelection.collapsed(offset: controller.text.length);
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  onChanged: (v) => f.key.text = v,
                  decoration: const InputDecoration(
                    labelText: '键',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: f.value,
              decoration: const InputDecoration(
                labelText: '值',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => _removeCredentialField(index),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '编辑资产' : '添加资产'),
        actions: [
          if (_isEdit && !_isLocalRepo)
            IconButton(
              tooltip: '设置继承人',
              icon: const Icon(Icons.people_outline),
              onPressed: () async {
                final asset = widget.asset;
                if (asset == null) return;
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AssetInheritorsPage(
                      assetId: asset.id,
                      assetName: asset.name,
                      repository: widget.repository,
                    ),
                  ),
                );
              },
            ),
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
                    DropdownButtonFormField<String>(
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
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '凭据(键值对)',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _addCredentialField,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('添加'),
                        ),
                      ],
                    ),
                    for (var i = 0; i < _credentialFields.length; i++)
                      _credentialRow(i),
                    if (_credentialFields.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          '添加账号、密码、恢复码等(可选)',
                          style: TextStyle(fontSize: 12, color: Colors.grey),
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
    // 分类不区分类型,展示全部(预设与自定义同表)。
    return [
      const DropdownMenuItem(value: '', child: Text('未分类')),
      ..._categories.map(
        (c) => DropdownMenuItem(
          value: c.id,
          child: Text(c.isPreset ? '${c.name}(预设)' : c.name),
        ),
      ),
    ];
  }
}

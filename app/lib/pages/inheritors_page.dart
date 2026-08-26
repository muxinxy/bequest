import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/inheritor.dart';
import '../repository/asset_repository.dart';
import '../storage/secure_store.dart';
import '../utils/validation.dart';
import 'inheritor_assets_page.dart';

/// 继承人管理:列表、新增、删除;点击行查看该继承人的绑定资产。
class InheritorsPage extends StatefulWidget {
  const InheritorsPage({super.key, required this.repository});

  final AssetRepository repository;

  @override
  State<InheritorsPage> createState() => _InheritorsPageState();
}

class _InheritorsPageState extends State<InheritorsPage> {
  late final Future<ApiClient> _api = ApiConfig.client();
  final _store = SecureStore();
  final _searchController = TextEditingController();
  final _scroll = ScrollController();

  List<Inheritor> _inheritors = const [];
  int? _defaultInheritorId;
  bool _loading = true;

  /// 本地分页:每页 20,滚动到底自动加载更多。
  static const _pageSize = 20;
  int _visibleCount = _pageSize;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 滚动接近底部时加载下一页。
  void _onScroll() {
    if (_scroll.position.extentAfter < 200) {
      setState(() => _visibleCount += _pageSize);
    }
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final api = await _api;
      final results = await Future.wait([
        api.listInheritors(jwt),
        api.getDefaultInheritor(jwt),
      ]);
      if (!mounted) return;
      final list = results[0] as List<Map<String, dynamic>>;
      final def = results[1] as Map<String, dynamic>;
      setState(() {
        _inheritors = list.map(Inheritor.fromJson).toList(growable: false);
        _defaultInheritorId = (def['inheritor_id'] as num?)?.toInt();
        _visibleCount = _pageSize;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  /// 生成 8 位随机字母数字访问码。
  static String _generateAccessCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return String.fromCharCodes(
      List.generate(8, (_) => chars.codeUnitAt(random.nextInt(chars.length))),
    );
  }

  Future<void> _addInheritor() async {
    final nameController = TextEditingController();
    final emailController = TextEditingController();
    final phoneController = TextEditingController();
    final codeController = TextEditingController();
    String? accessCode;

    final result = await showDialog<_InheritorDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('添加继承人'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '姓名 *',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: '邮箱(可选)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: '手机号(可选)',
                    helperText: '邮箱或手机号至少填一个',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: codeController,
                        decoration: const InputDecoration(
                          labelText: '访问码 *',
                          hintText: '8 位字母数字',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () {
                        accessCode = _generateAccessCode();
                        codeController.text = accessCode!;
                        setDialogState(() {});
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('生成'),
                    ),
                  ],
                ),
                if (accessCode != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '请立即将访问码线下告知继承人,此码仅现在可见,'
                    '触发继承后凭此码领取密钥。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                final email = emailController.text.trim();
                final phone = phoneController.text.trim();
                final code = codeController.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('请输入姓名')));
                  return;
                }
                if (email.isEmpty && phone.isEmpty) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('邮箱或手机号至少填一个')));
                  return;
                }
                if (email.isNotEmpty && !isValidEmail(email)) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('邮箱格式不正确')));
                  return;
                }
                if (phone.isNotEmpty && !isValidPhone(phone)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('手机号格式不正确(5-20 位数字)')),
                  );
                  return;
                }
                if (code.isEmpty) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('请输入或生成访问码')));
                  return;
                }
                Navigator.of(context).pop(
                  _InheritorDraft(
                    name: name,
                    email: email,
                    phone: phone,
                    accessCode: code,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    codeController.dispose();
    if (result == null) return;
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      await (await _api).createInheritor(jwt, {
        'name': result.name,
        'email': result.email,
        'phone': result.phone,
        'access_code': result.accessCode,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已添加继承人,请将访问码线下告知对方')));
      await _load();
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('添加失败,请检查网络后重试');
    }
  }

  /// 编辑继承人:改名称/邮箱/手机号/访问码(访问码留空则服务端不改)。
  Future<void> _editInheritor(Inheritor inheritor) async {
    final nameController = TextEditingController(text: inheritor.name);
    final emailController = TextEditingController(text: inheritor.email);
    final phoneController = TextEditingController(text: inheritor.phone);
    final codeController = TextEditingController();
    String? newCode;

    final result = await showDialog<_InheritorDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('编辑继承人'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '姓名 *',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: '邮箱(可选)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: '手机号(可选)',
                    helperText: '邮箱或手机号至少填一个',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: codeController,
                        decoration: InputDecoration(
                          labelText: '新继承码',
                          hintText: inheritor.accessCode.isEmpty
                              ? '8 位字母数字'
                              : '留空则不修改',
                          helperText: '留空表示不修改继承码',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () {
                        newCode = _generateAccessCode();
                        codeController.text = newCode!;
                        setDialogState(() {});
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('生成'),
                    ),
                  ],
                ),
                if (newCode != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '请立即将新的继承码线下告知继承人。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                final email = emailController.text.trim();
                final phone = phoneController.text.trim();
                if (name.isEmpty) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('请输入姓名')));
                  return;
                }
                if (email.isEmpty && phone.isEmpty) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('邮箱或手机号至少填一个')));
                  return;
                }
                if (email.isNotEmpty && !isValidEmail(email)) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('邮箱格式不正确')));
                  return;
                }
                if (phone.isNotEmpty && !isValidPhone(phone)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('手机号格式不正确(5-20 位数字)')),
                  );
                  return;
                }
                Navigator.of(context).pop(
                  _InheritorDraft(
                    name: name,
                    email: email,
                    phone: phone,
                    // 留空 = 不修改继承码;填了 = 重置。
                    accessCode: codeController.text.trim(),
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    codeController.dispose();
    if (result == null) return;
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final body = <String, dynamic>{
        'name': result.name,
        'email': result.email,
        'phone': result.phone,
      };
      if (result.accessCode.isNotEmpty) {
        body['access_code'] = result.accessCode;
      }
      await (await _api).updateInheritor(jwt, inheritor.id, body);
      await _load();
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('保存失败,请检查网络后重试');
    }
  }

  /// 复制继承码到剪贴板。
  Future<void> _copyAccessCode(Inheritor inheritor) async {
    await Clipboard.setData(ClipboardData(text: inheritor.accessCode));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('继承码已复制')));
  }

  Future<void> _deleteInheritor(Inheritor inheritor) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除继承人'),
        content: Text('确定删除继承人「${inheritor.name}」吗?'),
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
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      await (await _api).deleteInheritor(jwt, inheritor.id);
      await _load();
    } on ApiException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('删除失败,请检查网络后重试');
    }
  }

  /// 打开该继承人的绑定资产页(固定为该继承人)。
  void _openAssets(Inheritor inheritor) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => InheritorAssetsPage(
          repository: widget.repository,
          initialInheritorId: inheritor.id,
        ),
      ),
    );
  }

  /// 设为默认继承人:确认后 PUT default-inheritor,刷新 + SnackBar。
  Future<void> _setDefaultInheritor(Inheritor inheritor) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设为默认继承人'),
        content: Text('确定将「${inheritor.name}」设为默认继承人吗?\n'
            '继承触发时未指定继承人的资产将优先交接给 TA。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('设为默认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      await (await _api).putDefaultInheritor(jwt, int.tryParse(inheritor.id));
      await _load();
      if (!mounted) return;
      _showError('已设为默认继承人');
    } catch (_) {
      _showError('保存失败,请检查网络后重试');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // 本地过滤(姓名/邮箱)+ 分页截取。
    // API 未提供 q 参数,本地过滤;规模大时后端加分页搜索。
    final query = _search.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _inheritors
        : _inheritors
              .where(
                (i) =>
                    i.name.toLowerCase().contains(query) ||
                    i.email.toLowerCase().contains(query),
              )
              .toList();
    // 默认继承人置顶,其余按 priority 升序(第一顺位在前)。
    final sorted = [...filtered]..sort((a, b) {
        final aDef = a.id == '$_defaultInheritorId' ? 0 : 1;
        final bDef = b.id == '$_defaultInheritorId' ? 0 : 1;
        if (aDef != bDef) return aDef - bDef;
        return (a.priority ?? 1 << 30).compareTo(b.priority ?? 1 << 30);
      });
    final shown = sorted.take(_visibleCount).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('继承人管理')),
      floatingActionButton: FloatingActionButton(
        tooltip: '添加继承人',
        onPressed: _addInheritor,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.all(12),
            child: const Text(
              '继承码用于触发继承后领取资产密钥,请线下告知继承人;'
              '列表仅显示掩码,查看/重置请在编辑中点击"生成"。',
              style: TextStyle(fontSize: 12),
            ),
          ),
          // 搜索框:按姓名/邮箱本地过滤。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: '搜索姓名或邮箱',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _search = '';
                            _visibleCount = _pageSize;
                          });
                        },
                      ),
              ),
              onChanged: (value) => setState(() {
                _search = value;
                _visibleCount = _pageSize;
              }),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _inheritors.isEmpty
                ? const Center(child: Text('暂无继承人,点击右下角 + 添加'))
                : filtered.isEmpty
                ? const Center(child: Text('没有匹配的继承人'))
                : ListView.separated(
                    controller: _scroll,
                    itemCount: shown.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final inheritor = shown[index];
                      final isDefault =
                          inheritor.id == '$_defaultInheritorId';
                      return ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Row(
                          children: [
                            Flexible(child: Text(inheritor.name)),
                            if (isDefault) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.secondaryContainer,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '默认',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSecondaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${inheritor.email.isEmpty ? '未填写邮箱' : inheritor.email}'
                              '${inheritor.phone.isEmpty ? '' : ' · ${inheritor.phone}'}'
                              '${inheritor.priority == null ? '' : ' · 优先级 ${inheritor.priority}'}'
                              ' · ${inheritor.categoryCount} 个分组 · ${inheritor.assetCount} 个资产',
                            ),
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    '继承码:${inheritor.accessCode.isEmpty ? '未设置' : inheritor.accessCode}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                      fontFamily: 'monospace',
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (inheritor.accessCode.isNotEmpty &&
                                    !inheritor.accessCode.contains('*'))
                                  IconButton(
                                    tooltip: '复制继承码',
                                    visualDensity: VisualDensity.compact,
                                    icon: const Icon(
                                      Icons.copy_outlined,
                                      size: 16,
                                    ),
                                    onPressed: () => _copyAccessCode(inheritor),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        onTap: () => _openAssets(inheritor),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: isDefault ? '当前默认继承人' : '设为默认继承人',
                              icon: Icon(
                                isDefault
                                    ? Icons.star
                                    : Icons.star_outline,
                                color: isDefault
                                    ? Colors.amber
                                    : null,
                              ),
                              onPressed: isDefault
                                  ? null
                                  : () => _setDefaultInheritor(inheritor),
                            ),
                            IconButton(
                              tooltip: '查看绑定资产',
                              icon: const Icon(Icons.inventory_2_outlined),
                              onPressed: () => _openAssets(inheritor),
                            ),
                            IconButton(
                              tooltip: '编辑',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _editInheritor(inheritor),
                            ),
                            IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteInheritor(inheritor),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 对话框返回的草稿数据。
class _InheritorDraft {
  const _InheritorDraft({
    required this.name,
    required this.email,
    required this.phone,
    required this.accessCode,
  });

  final String name;
  final String email;
  final String phone;
  final String accessCode;
}

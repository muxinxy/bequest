import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../l10n/app_l10n.dart';
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
      ).showSnackBar(SnackBar(content: Text(L10n.tr('加载失败,请检查网络后重试'))));
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _InheritorDialog(store: _store, api: _api),
    );
    if (ok != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.tr('已添加继承人,请将访问码线下告知对方'))),
    );
    await _load();
  }

/// 编辑继承人:改名称/邮箱/手机号/访问码(访问码留空则服务端不改)。
  Future<void> _editInheritor(Inheritor inheritor) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => _InheritorDialog(
        inheritor: inheritor,
        store: _store,
        api: _api,
      ),
    );
    if (ok == true) await _load();
  }

  /// 复制继承码到剪贴板。
  Future<void> _copyAccessCode(Inheritor inheritor) async {
    await Clipboard.setData(ClipboardData(text: inheritor.accessCode));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(L10n.tr('继承码已复制'))));
  }

  Future<void> _deleteInheritor(Inheritor inheritor) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(L10n.tr('删除继承人')),
        content: Text(L10n.trp('确定删除继承人「{name}」吗?', {'name': inheritor.name})),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.tr('删除')),
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
      _showError(L10n.tr('删除失败,请检查网络后重试'));
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
        title: Text(L10n.tr('设为默认继承人')),
        content: Text(L10n.trp(
          '确定将「{name}」设为默认继承人吗?\n'
          '继承触发时未指定继承人的资产将优先交接给 TA。',
          {'name': inheritor.name},
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.tr('设为默认')),
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
      _showError(L10n.tr('已设为默认继承人'));
    } catch (_) {
      _showError(L10n.tr('保存失败,请检查网络后重试'));
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
      appBar: AppBar(title: Text(L10n.tr('继承人管理'))),
      floatingActionButton: FloatingActionButton(
        tooltip: L10n.tr('添加继承人'),
        onPressed: _addInheritor,
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.all(12),
            child: Text(
              L10n.tr(
                '继承码用于触发继承后领取资产密钥,请线下告知继承人;'
                '列表仅显示掩码,查看/重置请在编辑中点击"生成"。',
              ),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          // 搜索框:按姓名/邮箱本地过滤。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: L10n.tr('搜索姓名或邮箱'),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        tooltip: L10n.tr('清空'),
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
                ? Center(child: Text(L10n.tr('暂无继承人,点击右下角 + 添加')))
                : filtered.isEmpty
                ? Center(child: Text(L10n.tr('没有匹配的继承人')))
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
                                  L10n.tr('默认'),
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
                              '${inheritor.email.isEmpty ? L10n.tr('未填写邮箱') : inheritor.email}'
                              '${inheritor.phone.isEmpty ? '' : ' · ${inheritor.phone}'}'
                              '${inheritor.priority == null ? '' : ' · ${L10n.trp('优先级 {n}', {'n': '${inheritor.priority}'})}'}'
                              ' · ${L10n.trp('{n} 个分组', {'n': '${inheritor.categoryCount}'})}'
                              ' · ${L10n.trp('{n} 个资产', {'n': '${inheritor.assetCount}'})}',
                            ),
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    '${L10n.tr('继承码:')}${inheritor.accessCode.isEmpty ? L10n.tr('未设置') : inheritor.accessCode}',
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
                                    tooltip: L10n.tr('复制继承码'),
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
                              tooltip: isDefault
                                  ? L10n.tr('当前默认继承人')
                                  : L10n.tr('设为默认继承人'),
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
                              tooltip: L10n.tr('查看绑定资产'),
                              icon: const Icon(Icons.inventory_2_outlined),
                              onPressed: () => _openAssets(inheritor),
                            ),
                            IconButton(
                              tooltip: L10n.tr('编辑'),
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _editInheritor(inheritor),
                            ),
                            IconButton(
                              tooltip: L10n.tr('删除'),
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

/// 新增/编辑继承人对话框:姓名/邮箱/手机号/继承码;保存成功才 pop(true),失败保留输入。
class _InheritorDialog extends StatefulWidget {
  const _InheritorDialog({
    this.inheritor,
    required this.store,
    required this.api,
  });

  /// null = 新增;非 null = 编辑。
  final Inheritor? inheritor;
  final SecureStore store;
  final Future<ApiClient> api;

  @override
  State<_InheritorDialog> createState() => _InheritorDialogState();
}

class _InheritorDialogState extends State<_InheritorDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.inheritor?.name ?? '',
  );
  late final TextEditingController _emailController = TextEditingController(
    text: widget.inheritor?.email ?? '',
  );
  late final TextEditingController _phoneController = TextEditingController(
    text: widget.inheritor?.phone ?? '',
  );
  late final TextEditingController _codeController = TextEditingController();
  String? _newCode;
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.inheritor != null;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();
    String? error;
    if (name.isEmpty) {
      error = L10n.tr('请输入姓名');
    } else if (email.isEmpty && phone.isEmpty) {
      error = L10n.tr('邮箱或手机号至少填一个');
    } else if (email.isNotEmpty && !isValidEmail(email)) {
      error = L10n.tr('邮箱格式不正确');
    } else if (phone.isNotEmpty && !isValidPhone(phone)) {
      error = L10n.tr('手机号格式不正确(5-20 位数字)');
    } else if (code.isEmpty && !_isEdit) {
      error = L10n.tr('请输入或生成继承码');
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final jwt = await widget.store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final body = <String, dynamic>{
        'name': name,
        'email': email,
        'phone': phone,
      };
      // 编辑时继承码留空 = 不修改。
      if (code.isNotEmpty) body['access_code'] = code;
      final api = await widget.api;
      final inheritor = widget.inheritor;
      if (inheritor == null) {
        await api.createInheritor(jwt, body);
      } else {
        await api.updateInheritor(jwt, inheritor.id, body);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = L10n.tr('保存失败,请检查网络后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final inheritor = widget.inheritor;
    return AlertDialog(
      title: Text(_isEdit ? L10n.tr('编辑继承人') : L10n.tr('添加继承人')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: L10n.tr('姓名 *'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: L10n.tr('邮箱(可选)'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: L10n.tr('手机号(可选)'),
                helperText: L10n.tr('邮箱或手机号至少填一个'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _codeController,
                    decoration: InputDecoration(
                      labelText: _isEdit
                          ? L10n.tr('新继承码')
                          : L10n.tr('访问码 *'),
                      hintText: _isEdit
                          ? (inheritor!.accessCode.isEmpty
                              ? L10n.tr('8 位字母数字')
                              : L10n.tr('留空则不修改'))
                          : L10n.tr('8 位字母数字'),
                      helperText: _isEdit
                          ? L10n.tr('留空表示不修改继承码')
                          : null,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    _newCode = _InheritorsPageState._generateAccessCode();
                    _codeController.text = _newCode!;
                    setState(() {});
                  },
                  icon: const Icon(Icons.refresh),
                  label: Text(L10n.tr('生成')),
                ),
              ],
            ),
            if (_newCode != null) ...[
              const SizedBox(height: 12),
              Text(
                _isEdit
                    ? L10n.tr('请立即将新的继承码线下告知继承人。')
                    : L10n.tr(
                        '请立即将访问码线下告知继承人,此码仅现在可见,'
                        '触发继承后凭此码领取密钥。',
                      ),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text(L10n.tr('取消')),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? L10n.tr('保存中...') : L10n.tr('保存')),
        ),
      ],
    );
  }
}

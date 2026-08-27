import 'package:flutter/material.dart';

import '../crypto/key_derivation.dart';
import '../storage/secure_store.dart';
import '../sync/local_vault.dart';
import 'home_page.dart';
import 'sync_settings_page.dart';

/// 本地模式入口形态。
enum LocalUnlockStep { setup, pick, verify }

/// 入口判定:已有本地账户 → 选择账户;否则 → 新建。
/// (抽成纯函数便于单元测试)
LocalUnlockStep localUnlockStep({required bool hasProfiles}) =>
    hasProfiles ? LocalUnlockStep.pick : LocalUnlockStep.setup;

/// 进入本地模式(无需登录):首次新建本地账户(可多个,各自独立主密码与数据);
/// 再次进入必须验证该账户主密码。
class LocalUnlockPage extends StatefulWidget {
  const LocalUnlockPage({super.key});

  @override
  State<LocalUnlockPage> createState() => _LocalUnlockPageState();
}

class _LocalUnlockPageState extends State<LocalUnlockPage> {
  final _store = SecureStore();
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _hintController = TextEditingController();
  final _verifyController = TextEditingController();

  LocalUnlockStep _step = LocalUnlockStep.setup;
  List<Map<String, String>> _profiles = const [];
  Map<String, String> _verifyProfile = const {};
  String _verifyHint = '';
  bool _submitting = false;
  String? _verifyError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _hintController.dispose();
    _verifyController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    // 旧版单账户迁移:标准槽已有本地主密钥 → 登记为 legacy 账户(数据零迁移)。
    await _store.migrateLegacyLocalProfile();
    final profiles = await _store.readLocalProfiles();
    if (!mounted) return;
    final step = localUnlockStep(hasProfiles: profiles.isNotEmpty);
    setState(() {
      _profiles = profiles;
      _step = step;
    });
  }

  /// 新建本地账户。
  Future<void> _setupAccount() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      final salt = generateSalt();
      final mk = await deriveMasterKey(_passwordController.text, salt);
      final wrappingKey = generateWrappingKey();
      final id = 'p${DateTime.now().millisecondsSinceEpoch}';
      await _store.createLocalProfile(
        id: id,
        name: _nameController.text.trim(),
        masterKey: mk,
        salt: salt,
        wrappingKey: wrappingKey,
        hint: _hintController.text.trim(),
      );
      // 初始化空本地库(携带 salt,供跨设备恢复)。
      await LocalVault().saveLocalData(
        {
          'schema': 1,
          'assets': <Map<String, dynamic>>[],
          'categories': <Map<String, dynamic>>[],
        },
        mk,
        salt: salt,
      );
      await _store.saveStorageMode('local');
      _enterLocalHome();
    } catch (_) {
      _showError('创建本地账户失败,请重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 选择账户 → 进入验证步骤(主密码)。读取该账户提示语用于展示。
  Future<void> _pickAccount(Map<String, String> profile) async {
    final p = await _store.readLocalProfile(profile['id'] ?? '');
    if (!mounted) return;
    setState(() {
      _verifyProfile = profile;
      _verifyHint = p.hint ?? '';
      _verifyController.clear();
      _verifyError = null;
      _step = LocalUnlockStep.verify;
    });
  }

  /// 验证主密码(与账户盐派生比对)后激活并进入。
  Future<void> _verifyAccount() async {
    final password = _verifyController.text;
    if (password.isEmpty) return;
    setState(() {
      _submitting = true;
      _verifyError = null;
    });
    try {
      final profile = await _store.readLocalProfile(_verifyProfile['id'] ?? '');
      final salt = profile.salt;
      final mk = profile.mk;
      if (salt == null || salt.isEmpty || mk == null || mk.isEmpty) {
        setState(() => _verifyError = '账户数据缺失,请删除后重建');
        return;
      }
      final derived = await deriveMasterKey(password, salt);
      if (derived != mk) {
        setState(() => _verifyError = '主密码错误,请重试');
        return;
      }
      await _store.activateLocalProfile(_verifyProfile['id'] ?? '');
      await _store.saveStorageMode('local');
      _enterLocalHome();
    } catch (_) {
      setState(() => _verifyError = '验证失败,请重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 删除本地账户(确认后;当前账户先退出)。
  Future<void> _deleteAccount(Map<String, String> profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除本地账户「${profile['name'] ?? ''}」?'),
        content: const Text('该账户的本地数据将被移除(不可恢复)。'),
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
    if (confirmed != true || !mounted) return;
    await _store.deleteLocalProfile(profile['id'] ?? '');
    await _init();
  }

  /// 重命名本地账户:名称不能与其他账户相同。
  Future<void> _renameAccount(Map<String, String> profile) async {
    final controller = TextEditingController(text: profile['name'] ?? '');
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名账户'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(
            labelText: '账户名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              // 校验失败不关闭弹框:空名称直接提示并留在对话框内。
              if (name.isEmpty) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('请输入账户名称')));
                return;
              }
              Navigator.of(context).pop(name);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || !mounted) return;
    final ok = await _store.renameLocalProfile(profile['id'] ?? '', newName);
    if (!mounted) return;
    if (!ok) {
      _showError('名称已被其他账户使用');
      return;
    }
    await _init();
  }

  Future<void> _enterLocalHome() async {
    if (!mounted) return;
    await _store.saveStorageMode('local');
    if (!mounted) return;
    // 清空登录页栈底:本地模式只能经右上角"退出本地模式"回登录页,
    // 系统返回(Android)直接退出 APP,而非露出登录页。
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const HomePage()),
      (route) => false,
    );
  }

  Future<void> _goRestore() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SyncSettingsPage()));
    // 恢复流程可能已写入主密钥,重新判定入口形态。
    await _init();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // 本地模式入口(账户列表/新建/验证):允许返回登录页——
    // 用户可能只是进来看看,不该被困在列表页。
    return Scaffold(
      appBar: AppBar(
        title: const Text('进入本地模式'),
        automaticallyImplyLeading: true,
      ),
      body: switch (_step) {
        LocalUnlockStep.pick => _buildPicker(),
        LocalUnlockStep.verify => _buildVerify(),
        LocalUnlockStep.setup => _buildSetup(),
      },
    );
  }

  Widget _buildPicker() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            '选择本地账户',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        for (final p in _profiles)
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(p['name'] ?? ''),
              subtitle: Text(p['id'] ?? ''),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '重命名',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _renameAccount(p),
                  ),
                  IconButton(
                    tooltip: '删除账户',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteAccount(p),
                  ),
                ],
              ),
              onTap: () => _pickAccount(p),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: () => setState(() {
            _step = LocalUnlockStep.setup;
          }),
          icon: const Icon(Icons.add),
          label: const Text('新建本地账户'),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _goRestore,
          child: Text(
            '从备份恢复(需主密码)',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVerify() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.lock_outline, size: 64),
          const SizedBox(height: 8),
          Text(
            '验证「${_verifyProfile['name'] ?? ''}」主密码',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
          ),
          const SizedBox(height: 4),
          Text(
            '本地数据由主密码加密,验证后进入',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (_verifyHint.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '主密码提示: $_verifyHint',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 24),
          TextField(
            controller: _verifyController,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: '主密码',
              border: const OutlineInputBorder(),
              errorText: _verifyError,
            ),
            onSubmitted: (_) => _verifyAccount(),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _submitting ? null : _verifyAccount,
            child: _submitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('进入'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() => _step = LocalUnlockStep.pick),
            child: Text(
                  '返回账户列表',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildSetup() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.offline_pin_outlined, size: 64),
            const SizedBox(height: 8),
            const Text(
              '新建本地账户',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
            ),
            const SizedBox(height: 4),
            Text(
              '本地模式无需登录,数据加密保存在本机;可创建多个账户',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _nameController,
              maxLength: 20,
              decoration: const InputDecoration(
                labelText: '账户名称',
                hintText: '如:张三 / 家人共用的保险箱',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  (value == null || value.trim().isEmpty) ? '请输入账户名称' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '主密码',
                helperText: '至少 8 位,用于加密本地数据',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  (value == null || value.length < 8) ? '主密码至少 8 位' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirmController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '确认主密码',
                border: OutlineInputBorder(),
              ),
              validator: (value) => value != _passwordController.text
                  ? '两次输入的主密码不一致'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _hintController,
              maxLength: 50,
              decoration: const InputDecoration(
                labelText: '主密码提示语(可选)',
                hintText: '帮助回忆的提示,仅保存在本机',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submitting ? null : _setupAccount,
              child: _submitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('创建并进入'),
            ),
            if (_profiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() => _step = LocalUnlockStep.pick),
child: Text(
              '返回账户列表',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

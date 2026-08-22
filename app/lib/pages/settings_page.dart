import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../models/asset.dart';
import '../models/entitlements.dart';
import '../repository/asset_repository.dart';
import '../repository/local_asset_repository.dart';
import '../storage/secure_store.dart';
import '../main.dart' show BequestApp;
import 'about_page.dart';
import 'account_settings_page.dart';
import 'app_lock_setup_page.dart';
import 'change_master_password_page.dart';
import 'excel_export_page.dart';
import 'export_page.dart';
import 'import_page.dart';
import 'inheritance_status_page.dart';
import 'inheritor_assets_page.dart';
import 'inheritors_page.dart';
import 'log_page.dart';
import 'reminder_templates_page.dart';
import 'reset_master_password_page.dart';
import 'server_settings_page.dart';
import 'smtp_settings_page.dart';
import 'sync_settings_page.dart';
import 'trigger_ladders_page.dart';

/// 设置:二级聚合页,收纳主页 AppBar 中拥挤的菜单项。
/// 各项只做跳转或小交互,页面逻辑复用现有页面,不复制实现。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.repository});

  final AssetRepository repository;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _store = SecureStore();

  /// 全局继承开关(仅云端模式有意义;本地模式无继承)。
  bool _inheritanceEnabled = true;
  bool _hasJwt = false;

  /// 本地模式:需登录的功能(提醒模板/继承人/继承状态等)置灰。
  bool get _isLocal => widget.repository is LocalAssetRepository;

  @override
  void initState() {
    super.initState();
    _loadToggle();
  }

  Future<void> _loadToggle() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null || jwt.isEmpty) return;
      final api = await ApiConfig.client();
      final res = await api.getInheritanceToggle(jwt);
      if (mounted) {
        setState(() {
          _hasJwt = true;
          _inheritanceEnabled = res['enabled'] == true;
        });
      }
    } catch (_) {
      // 未登录/网络失败:保持默认。
    }
  }

  Future<void> _toggleInheritance(bool value) async {
    setState(() => _inheritanceEnabled = value);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) return;
      await (await ApiConfig.client()).putInheritanceToggle(jwt, value);
    } catch (_) {
      if (!mounted) return;
      setState(() => _inheritanceEnabled = !value);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('开关保存失败,请检查网络后重试')));
    }
  }

  Future<void> _exportFlow(BuildContext context) async {
    final assets = await widget.repository.listAssets().then(
      (list) => list.map(Asset.fromJson).toList(),
    );
    if (!context.mounted) return;
    if (assets.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无资产可导出')));
      return;
    }
    // 导出方式:JSON(可选加密) / Excel(会员)。
    final jwt = await _store.readJwt();
    final ent = Entitlements.forJwtAndTier(
      hasJwt: jwt != null && jwt.isNotEmpty,
      tier: _isLocal ? null : await _currentTier(jwt),
    );
    if (!context.mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('导出资产'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('json'),
            child: const ListTile(
              leading: Icon(Icons.code),
              title: Text('JSON(可加密)'),
              subtitle: Text('通用格式,可再导入'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => ent.exportExcel
                ? Navigator.of(context).pop('excel')
                : Navigator.of(context).pop('excel_locked'),
            child: ListTile(
              leading: const Icon(Icons.table_chart),
              title: const Text('Excel 表格'),
              subtitle: Text(
                ent.exportExcel ? '表格查看,适合打印分享' : '会员权益,升级后可用',
              ),
            ),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'excel_locked') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Excel 导出为会员权益,请联系管理员开通会员')),
      );
      return;
    }
    if (choice == 'excel') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ExcelExportPage(assets: assets, repository: widget.repository),
        ),
      );
      return;
    }
    // JSON:可选加密。
    final encrypt = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出资产'),
        content: const Text('是否用主密码加密导出文件?\n加密后文件无法直接查看,导入时需验证主密码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('不加密'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('加密'),
          ),
        ],
      ),
    );
    if (encrypt == null || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ExportPage(assets: assets, repository: widget.repository, encrypt: encrypt),
      ),
    );
  }

  /// 当前会员层级(仅云端;本地模式返回 null → 访客权益)。
  Future<String?> _currentTier(String? jwt) async {
    if (jwt == null || jwt.isEmpty) return null;
    try {
      final me = await (await ApiConfig.client()).me(jwt);
      return (me['user'] as Map<String, dynamic>?)?['tier'] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> _importFlow(BuildContext context) async {
    // 用官方 file_selector(无自定义 Gradle 插件,CI 可编译;file_picker 有 KGP 兼容问题)。
    const typeGroup = XTypeGroup(
      label: 'JSON / 加密导出文件',
      extensions: ['json', 'beq'],
    );
    try {
      final file = await openFile(acceptedTypeGroups: const [typeGroup]);
      if (file == null) return;
      final text = await file.readAsString();
      if (!context.mounted) return;
      // 覆盖导入:清空现有资产后再导入(破坏性操作,需确认)。
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('导入资产'),
          content: const Text('是否覆盖现有资产?\n覆盖会先删除当前全部资产再导入(不可恢复)。选择"否"则追加导入。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('追加'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('覆盖'),
            ),
          ],
        ),
      );
      if (overwrite == null || !context.mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImportPage(
            fileText: text,
            repository: widget.repository,
            overwrite: overwrite,
          ),
        ),
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('读取文件失败')));
    }
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _section(context, '数据'),
          _entry(
            Icons.file_download_outlined,
            '导入资产',
            () => _importFlow(context),
          ),
          _entry(
            Icons.file_upload_outlined,
            '导出资产',
            () => _exportFlow(context),
          ),
          _section(context, '提醒'),
          _entry(
            Icons.event_note_outlined,
            '提醒模板',
            () => _push(context, const ReminderTemplatesPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.people_outline,
            '继承人',
            () => _push(context, const InheritorsPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.format_list_numbered_outlined,
            '触发阶梯',
            () => _push(context, const TriggerLaddersPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.flag_outlined,
            '继承状态',
            () => _push(context, const InheritanceStatusPage()),
            enabled: !_isLocal,
          ),
          // 全局继承开关:一键开启/关闭继承功能(关闭后不再升级提醒/触发交接)。
          SwitchListTile(
            secondary: const Icon(Icons.power_settings_new),
            title: const Text('继承开关'),
            subtitle: Text(
              _hasJwt ? '关闭后不触发继承交接' : '仅登录后可用',
              style: const TextStyle(fontSize: 12),
            ),
            value: _inheritanceEnabled,
            onChanged: _hasJwt ? _toggleInheritance : null,
          ),
          _entry(
            Icons.people_alt_outlined,
            '继承人绑定资产',
            () => _push(context, InheritorAssetsPage(repository: widget.repository)),
            enabled: !_isLocal,
          ),
          _section(context, '账户与安全'),
          _entry(
            Icons.person_outline,
            '账号信息',
            () => _push(context, const AccountSettingsPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.lock_outline,
            '应用锁',
            () => _push(context, const AppLockSetupPage()),
          ),
          _entry(
            Icons.password_outlined,
            '修改主密码',
            () => _push(context, const ChangeMasterPasswordPage()),
          ),
          _entry(
            Icons.restart_alt_outlined,
            '重置主密码(忘记)',
            () => _push(context, const ResetMasterPasswordPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.mail_outline,
            '邮箱发件设置',
            () => _push(context, const SmtpSettingsPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.article_outlined,
            '操作记录',
            () => _push(context, const LogPage()),
          ),
          _section(context, '外观'),
          _entry(
            Icons.palette_outlined,
            '主题',
            _pickTheme,
          ),
          _section(context, '存储与服务器'),
          _entry(
            Icons.dns_outlined,
            '服务器地址',
            () => _push(context, const ServerSettingsPage()),
          ),
          _entry(
            Icons.sync_outlined,
            '同步设置',
            () => _push(context, const SyncSettingsPage()),
          ),
          _section(context, '关于'),
          _entry(
            Icons.info_outline,
            '关于本应用',
            () => _push(context, const AboutPage()),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _section(BuildContext context, String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );

  Widget _entry(
    IconData icon,
    String title,
    VoidCallback onTap, {
    bool enabled = true,
  }) => ListTile(
    leading: Icon(icon, color: enabled ? null : Colors.grey),
    title: Text(
      title,
      style: enabled ? null : const TextStyle(color: Colors.grey),
    ),
    trailing: Icon(Icons.chevron_right, color: enabled ? null : Colors.grey),
    onTap: enabled ? onTap : null,
  );

  /// 主题选择:浅色 / 深色 / 跟随系统。
  Future<void> _pickTheme() async {
    final current = await _store.readThemeMode() ?? 'system';
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('主题'),
        children: [
          _themeOption('system', '跟随系统', current),
          _themeOption('light', '浅色', current),
          _themeOption('dark', '深色', current),
        ],
      ),
    );
    if (choice == null || choice == current) return;
    await _store.saveThemeMode(choice);
    // 刷新 MaterialApp 主题。
    BequestApp.notifyThemeChanged();
  }

  Widget _themeOption(String value, String label, String current) {
    return SimpleDialogOption(
      onPressed: () => Navigator.of(context).pop(value),
      child: Row(
        children: [
          Icon(
            value == 'system'
                ? Icons.brightness_auto
                : value == 'light'
                    ? Icons.light_mode
                    : Icons.dark_mode,
            color: current == value ? Theme.of(context).colorScheme.primary : null,
          ),
          const SizedBox(width: 12),
          Text(label),
          if (current == value) ...[
            const Spacer(),
            Icon(
              Icons.check,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ],
      ),
    );
  }
}

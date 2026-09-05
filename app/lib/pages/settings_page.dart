import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../api/api_config.dart';
import '../l10n/app_l10n.dart';
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
import 'inheritance_page.dart';
import 'inheritors_page.dart';
import 'log_page.dart';
import 'notification_channels_page.dart';
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

  /// 本地模式:需登录的功能(提醒模板/继承人/继承状态等)置灰。
  bool get _isLocal => widget.repository is LocalAssetRepository;

  Future<void> _exportFlow(BuildContext context) async {
    final assets = await widget.repository.listAssets().then(
      (list) => list.map(Asset.fromJson).toList(),
    );
    if (!context.mounted) return;
    if (assets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.tr('暂无资产可导出'))),
      );
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
        title: Text(L10n.tr('导出资产')),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('json'),
            child: ListTile(
              leading: const Icon(Icons.code),
              title: Text(L10n.tr('JSON(可加密)')),
              subtitle: Text(L10n.tr('通用格式,可再导入')),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => ent.exportExcel
                ? Navigator.of(context).pop('excel')
                : Navigator.of(context).pop('excel_locked'),
            child: ListTile(
              leading: const Icon(Icons.table_chart),
              title: Text(L10n.tr('Excel 表格')),
              subtitle: Text(
                ent.exportExcel
                    ? L10n.tr('表格查看,适合打印分享')
                    : L10n.tr('会员权益,升级后可用'),
              ),
            ),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    if (choice == 'excel_locked') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.tr('Excel 导出为会员权益,请联系管理员开通会员'))),
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
        title: Text(L10n.tr('导出资产')),
        content: Text(L10n.tr('是否用主密码加密导出文件?\n加密后文件无法直接查看,导入时需验证主密码。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(L10n.tr('不加密')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(L10n.tr('加密')),
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
    final typeGroup = XTypeGroup(
      label: L10n.tr('JSON / 加密导出文件'),
      extensions: ['json', 'beq'],
    );
    try {
      final file = await openFile(acceptedTypeGroups: [typeGroup]);
      if (file == null) return;
      final text = await file.readAsString();
      if (!context.mounted) return;
      // 覆盖导入:清空现有资产后再导入(破坏性操作,需确认)。
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(L10n.tr('导入资产')),
          content: Text(L10n.tr('是否覆盖现有资产?\n覆盖会先删除当前全部资产再导入(不可恢复)。选择"否"则追加导入。')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(L10n.tr('追加')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(L10n.tr('覆盖')),
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
      ).showSnackBar(SnackBar(content: Text(L10n.tr('读取文件失败'))));
    }
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(L10n.tr('设置'))),
      body: ListView(
        children: [
          _section(context, L10n.tr('数据')),
          _entry(
            Icons.file_download_outlined,
            L10n.tr('导入资产'),
            () => _importFlow(context),
          ),
          _entry(
            Icons.file_upload_outlined,
            L10n.tr('导出资产'),
            () => _exportFlow(context),
          ),
          _section(context, L10n.tr('提醒')),
          _entry(
            Icons.event_note_outlined,
            L10n.tr('提醒模板'),
            () => _push(context, const ReminderTemplatesPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.format_list_numbered_outlined,
            L10n.tr('触发阶梯'),
            () => _push(context, const TriggerLaddersPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.flag_outlined,
            L10n.tr('继承'),
            () => _push(context, const InheritancePage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.people_outline,
            L10n.tr('继承人'),
            () => _push(context, InheritorsPage(repository: widget.repository)),
            enabled: !_isLocal,
          ),
          _section(context, L10n.tr('账户与安全')),
          _entry(
            Icons.person_outline,
            L10n.tr('账号信息'),
            () => _push(context, const AccountSettingsPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.notifications_outlined,
            L10n.tr('通知渠道'),
            () => _push(context, const NotificationChannelsPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.lock_outline,
            L10n.tr('应用锁'),
            () => _push(context, const AppLockSetupPage()),
          ),
          _entry(
            Icons.password_outlined,
            L10n.tr('修改主密码'),
            () => _push(context, const ChangeMasterPasswordPage()),
          ),
          _entry(
            Icons.restart_alt_outlined,
            L10n.tr('重置主密码(忘记)'),
            () => _push(context, const ResetMasterPasswordPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.mail_outline,
            L10n.tr('邮箱发件设置'),
            () => _push(context, const SmtpSettingsPage()),
            enabled: !_isLocal,
          ),
          _entry(
            Icons.article_outlined,
            L10n.tr('操作记录'),
            () => _push(context, const LogPage()),
          ),
          _section(context, L10n.tr('外观')),
          _entry(
            Icons.palette_outlined,
            L10n.tr('主题'),
            _pickTheme,
          ),
          _entry(
            Icons.language_outlined,
            L10n.tr('语言'),
            _pickLanguage,
          ),
          _section(context, L10n.tr('存储与服务器')),
          _entry(
            Icons.dns_outlined,
            L10n.tr('服务器地址'),
            () => _push(context, const ServerSettingsPage()),
          ),
          _entry(
            Icons.sync_outlined,
            L10n.tr('同步设置'),
            () => _push(context, const SyncSettingsPage()),
          ),
          _section(context, L10n.tr('关于')),
          _entry(
            Icons.info_outline,
            L10n.tr('关于本应用'),
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

  /// 语言选择:简体中文 / English。
  Future<void> _pickLanguage() async {
    final current = await _store.readLocale() ?? 'zh';
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('语言 / Language'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('zh'),
            child: Row(
              children: [
                const Icon(Icons.translate),
                const SizedBox(width: 12),
                Text('简体中文'),
                if (current == 'zh') ...[
                  const Spacer(),
                  Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ],
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('en'),
            child: Row(
              children: [
                const Icon(Icons.translate),
                const SizedBox(width: 12),
                const Text('English'),
                if (current == 'en') ...[
                  const Spacer(),
                  Icon(
                    Icons.check,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    if (choice == null || choice == current) return;
    await _store.saveLocale(choice);
    BequestApp.notifyLocaleChanged();
  }

  /// 主题选择:浅色 / 深色 / 跟随系统。
  Future<void> _pickTheme() async {
    final current = await _store.readThemeMode() ?? 'system';
    if (!mounted) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(L10n.tr('主题')),
        children: [
          _themeOption('system', L10n.tr('跟随系统'), current),
          _themeOption('light', L10n.tr('浅色'), current),
          _themeOption('dark', L10n.tr('深色'), current),
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

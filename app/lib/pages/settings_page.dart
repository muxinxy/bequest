import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../models/asset.dart';
import '../repository/asset_repository.dart';
import 'about_page.dart';
import 'app_lock_setup_page.dart';
import 'audit_page.dart';
import 'category_page.dart';
import 'change_master_password_page.dart';
import 'export_page.dart';
import 'import_page.dart';
import 'inheritance_status_page.dart';
import 'inheritors_page.dart';
import 'reminder_templates_page.dart';
import 'server_settings_page.dart';
import 'smtp_settings_page.dart';
import 'sync_settings_page.dart';

/// 设置:二级聚合页,收纳主页 AppBar 中拥挤的菜单项。
/// 各项只做跳转或小交互,页面逻辑复用现有页面,不复制实现。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.repository});

  final AssetRepository repository;

  Future<void> _exportFlow(BuildContext context) async {
    final assets = await repository.listAssets().then(
      (list) => list.map(Asset.fromJson).toList(),
    );
    if (!context.mounted) return;
    if (assets.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无资产可导出')));
      return;
    }
    // 可选加密导出:加密文件(.beq)需主密码才能解密导入。
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
            ExportPage(assets: assets, repository: repository, encrypt: encrypt),
      ),
    );
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
            repository: repository,
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
            Icons.category_outlined,
            '分类管理',
            () => _push(context, CategoryPage(repository: repository)),
          ),
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
          ),
          _entry(
            Icons.people_outline,
            '继承人',
            () => _push(context, const InheritorsPage()),
          ),
          _entry(
            Icons.flag_outlined,
            '继承状态',
            () => _push(context, const InheritanceStatusPage()),
          ),
          _section(context, '账户与安全'),
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
            Icons.mail_outline,
            '邮箱发件设置',
            () => _push(context, const SmtpSettingsPage()),
          ),
          _entry(
            Icons.receipt_long_outlined,
            '审计日志',
            () => _push(context, const AuditPage()),
          ),
          _section(context, '存储与服务器'),
          _entry(
            Icons.cloud_outlined,
            '存储模式',
            () => _push(context, const ServerSettingsPage(showUrl: false)),
          ),
          _entry(
            Icons.dns_outlined,
            '服务器地址',
            () => _push(context, const ServerSettingsPage(showMode: false)),
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

  Widget _entry(IconData icon, String title, VoidCallback onTap) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}

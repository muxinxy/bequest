import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../logger.dart';
import '../platform/file_share.dart';

/// 关于本应用:版本信息、简介、GitHub 链接、日志导出/清空。
/// 所有插件调用都包 try/catch,插件缺失或失败时回退,不影响页面展示。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  static const String _productVersion = 'v0.6.1';
  // ponytail: package_info_plus 读不到时回退到 pubspec 的 version 字段(模板默认值)。
  static const String _fallbackBuildVersion = '1.0.0+1';
  static const String _packageName = 'com.bequest.bequest';
  static const String _githubUrl = 'https://github.com/muxinxy/bequest';

  String _buildVersion = _fallbackBuildVersion;

  @override
  void initState() {
    super.initState();
    _loadBuildVersion();
  }

  Future<void> _loadBuildVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = '${info.version}+${info.buildNumber}';
      if (mounted) setState(() => _buildVersion = version);
    } catch (_) {
      // 插件不可用:保持回退值。
    }
  }

  Future<void> _openGitHub() async {
    try {
      final ok = await launchUrl(
        Uri.parse(_githubUrl),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) await _copyGitHubUrl();
    } catch (_) {
      // 无浏览器/插件缺失:退回复制链接。
      await _copyGitHubUrl();
    }
  }

  Future<void> _copyGitHubUrl() async {
    await Clipboard.setData(const ClipboardData(text: _githubUrl));
    if (!mounted) return;
    _snack('链接已复制到剪贴板');
  }

  Future<void> _exportLog() async {
    try {
      final log = await Logger.instance.readLog();
      if (log.trim().isEmpty) {
        _snack('暂无日志');
        return;
      }
      final ok = await shareTextFile('bequest_logs.txt', log, '托孤调试日志');
      if (!ok && mounted) _snack('导出日志失败');
    } catch (_) {
      if (!mounted) return;
      _snack('导出日志失败');
    }
  }

  Future<void> _clearLog() async {
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('确定要清空本地调试日志吗?此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await Logger.instance.clear();
      _snack('日志已清空');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于本应用')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 8),
          const Text(
            '托孤',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const Text(
            'bequest',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          _infoRow('应用版本', _productVersion),
          _infoRow('构建版本', _buildVersion),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text('包名'),
            trailing: SelectableText(_packageName),
          ),
          const SizedBox(height: 8),
          const Text(
            '简介',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 4),
          const Text(
            '数字资产保险箱 + 数字遗嘱。端到端加密,自托管同步,继承交接。'
            '您的资产凭据只属于您自己。',
            style: TextStyle(fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.link),
            title: const Text('GitHub'),
            subtitle: SelectableText(_githubUrl),
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              tooltip: '复制链接',
              onPressed: _copyGitHubUrl,
            ),
            onTap: _openGitHub,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('导出日志'),
            onPressed: _exportLog,
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            icon: const Icon(Icons.delete_outline),
            label: const Text('清空日志'),
            onPressed: _clearLog,
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.tag),
    title: Text(label),
    trailing: Text(value, style: const TextStyle(fontSize: 14)),
  );
}

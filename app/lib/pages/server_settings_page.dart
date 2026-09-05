import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api/api_config.dart';
import '../l10n/app_l10n.dart';
import '../storage/secure_store.dart';

/// 服务器设置:配置服务器地址(立即生效)。
class ServerSettingsPage extends StatefulWidget {
  const ServerSettingsPage({super.key});

  @override
  State<ServerSettingsPage> createState() => _ServerSettingsPageState();
}

class _ServerSettingsPageState extends State<ServerSettingsPage> {
  final _store = SecureStore();
  final _urlController = TextEditingController();

  bool _busy = false;

  /// 最近使用过的服务器地址(新→旧,最多 5 条)。
  List<String> _recentUrls = const [];

  /// 连接状态:null = 未测试;true = 成功;false = 失败。
  bool? _connectionOk;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final url = await ApiConfig.baseUrl();
    final recentRaw = await _store.readRecentUrls();
    if (!mounted) return;
    setState(() {
      _urlController.text = url;
      _recentUrls = recentRaw;
    });
    // 进入页面即测试连接,指示灯显示上次结果。
    await _testConnection(quiet: true);
  }

  Future<void> _saveUrl() async {
    final url = _urlController.text.trim().replaceFirst(RegExp(r'/+$'), '');
    if (url.isEmpty) {
      _snack(L10n.tr('请输入服务器地址'));
      return;
    }
    // 先验证连接,验证有效才保存。
    if (!await _testConnection(quiet: false)) {
      _snack(L10n.tr('无法连接服务器,请检查地址'));
      return;
    }
    // 记入最近地址(去重置顶,最多 5 条)。
    final recent = [url, ..._recentUrls.where((u) => u != url)];
    await _store.saveRecentUrls(recent.take(5).toList());
    await ApiConfig.setBaseUrl(url);
    if (!mounted) return;
    setState(() => _recentUrls = recent.take(5).toList());
    _snack(L10n.tr('已保存'));
  }

  /// 测试与指定地址的连接,返回是否可达;更新指示灯。
  Future<bool> _testConnection({bool quiet = false}) async {
    final url = _urlController.text.trim().replaceFirst(RegExp(r'/+$'), '');
    if (url.isEmpty) {
      if (!quiet) _snack(L10n.tr('请输入服务器地址'));
      return false;
    }
    if (!quiet) setState(() => _busy = true);
    var ok = false;
    try {
      final res = await http
          .get(Uri.parse('$url/api/v1/version'))
          .timeout(const Duration(seconds: 3));
      ok = res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      ok = false;
    }
    if (!mounted) return ok;
    setState(() {
      _connectionOk = ok;
      if (!quiet) _busy = false;
    });
    return ok;
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
      appBar: AppBar(title: Text(L10n.tr('服务器设置'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(L10n.tr('服务器地址'), style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextFormField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: 'http://10.0.2.2:8080',
              border: const OutlineInputBorder(),
              // 连接指示灯:绿=可用,红=不可用,灰=未测试。
              suffixIcon: Padding(
                padding: const EdgeInsets.all(12),
                child: _connectionOk == null
                    ? null
                    : Icon(
                        _connectionOk == true ? Icons.circle : Icons.circle,
                        size: 14,
                        color: _connectionOk == true
                            ? Colors.green
                            : Colors.red,
                      ),
              ),
            ),
          ),
          if (_recentUrls.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final url in _recentUrls)
                  InputChip(
                    label: Text(url, style: const TextStyle(fontSize: 12)),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onPressed: () {
                      _urlController.text = url;
                      setState(() => _connectionOk = null);
                      _testConnection(quiet: true);
                    },
                    onDeleted: () async {
                      final recent =
                          _recentUrls.where((u) => u != url).toList();
                      await _store.saveRecentUrls(recent);
                      if (mounted) {
                        setState(() => _recentUrls = recent);
                      }
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : _saveUrl,
            child: Text(L10n.tr('保存')),
          ),
        ],
      ),
    );
  }
}

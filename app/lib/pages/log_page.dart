import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../platform/file_share.dart';
import '../storage/secure_store.dart';
import '../utils/time_format.dart';

/// 日志页:审计/应用日志查看、CSV 导出、按月清除。
/// kind 筛选:'' = 全部,'audit' = 审计,'app' = 应用;年月从 /logs/months 推导。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final _store = SecureStore();

  String _kind = '';
  List<Map<String, dynamic>> _logs = const [];
  List<String> _months = const [];
  String? _year;
  String? _month;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<ApiClient> get _api => ApiConfig.client();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final api = await _api;
      final months = await api.listLogMonths(jwt);
      final logs = await api.listLogs(jwt, kind: _kind, month: _month ?? '');
      if (!mounted) return;
      setState(() {
        _months = months;
        _logs = logs;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
    }
  }

  /// 年份下拉:全部 + 有日志的年份。
  List<String> get _years {
    final years = <String>{for (final m in _months) m.substring(0, 4)};
    return ['全部', ...years.toList()..sort()];
  }

  /// 月份下拉:全部 + 选中年份下的月份(未选年份 = 全部月份)。
  List<String> get _monthOptions {
    final list = _year == null || _year == '全部'
        ? _months
        : _months.where((m) => m.startsWith(_year!)).toList();
    return ['全部', ...list];
  }

  Future<void> _export() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final csv = await (await _api).exportLogs(
        jwt,
        kind: _kind,
        month: _month ?? '',
      );
      final ok = await shareTextFile(
        'logs_${DateTime.now().millisecondsSinceEpoch}.csv',
        csv,
        '托孤日志导出(CSV)',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '导出成功' : '导出失败,请检查网络后重试')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('导出失败,请检查网络后重试')));
    }
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除日志'),
        content: const Text('确定清除当前筛选下的日志吗?此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final res = await (await _api).clearLogs(
        jwt,
        kind: _kind,
        month: _month ?? '',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已清除 ${res['deleted'] ?? 0} 条日志')),
      );
      await _load();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('清除失败,请检查网络后重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          IconButton(
            tooltip: '导出 CSV',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _export,
          ),
          IconButton(
            tooltip: '清除日志',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          // kind 筛选:全部 / 审计 / 应用。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: '', label: Text('全部')),
                ButtonSegment(value: 'audit', label: Text('审计')),
                ButtonSegment(value: 'app', label: Text('应用')),
              ],
              selected: {_kind},
              onSelectionChanged: (s) {
                setState(() => _kind = s.first);
                _load();
              },
            ),
          ),
          // 年月筛选:年份 + 月份(可用月份从 months 推导)。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _year ?? '全部',
                    decoration: const InputDecoration(
                      labelText: '年份',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final y in _years)
                        DropdownMenuItem(value: y, child: Text(y)),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _year = v;
                        _month = null;
                      });
                      _load();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _month ?? '全部',
                    decoration: const InputDecoration(
                      labelText: '月份',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final m in _monthOptions)
                        DropdownMenuItem(value: m, child: Text(m)),
                    ],
                    onChanged: (v) {
                      setState(() => _month = v == '全部' ? null : v);
                      _load();
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _logs.isEmpty
                    ? const Center(child: Text('暂无日志'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _logs.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final log = _logs[index];
                            final action = log['action']?.toString() ?? '';
                            final detail = log['detail']?.toString();
                            final createdAt = log['created_at']?.toString();
                            final isAudit = '${log['kind']}' == 'audit';
                            return ListTile(
                              leading: Icon(
                                isAudit
                                    ? Icons.verified_user_outlined
                                    : Icons.history,
                              ),
                              title: Text(action),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (detail != null && detail.isNotEmpty)
                                    Text(detail),
                                  Text(
                                    '${isAudit ? '审计' : '应用'}'
                                    '${createdAt == null || createdAt.isEmpty ? '' : ' · ${formatServerTime(createdAt)}'}',
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
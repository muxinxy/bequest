import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../platform/file_share.dart';
import '../storage/secure_store.dart';
import '../utils/time_format.dart';

/// 操作记录页:审计日志查看、CSV 导出、按月清除。
/// debug=true 时为调试模式:显示全部(审计+应用)日志,含 detail 原始 JSON。
/// kind 筛选:'' = 全部,'audit' = 审计,'app' = 应用;年月从 /logs/months 推导。
class LogPage extends StatefulWidget {
  const LogPage({super.key, this.debug = false});

  /// 调试模式:显示全部日志与 detail,标题"调试日志"。
  final bool debug;

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final _store = SecureStore();

  List<Map<String, dynamic>> _logs = const [];
  List<String> _months = const [];
  String? _year;
  String? _month;
  bool _loading = true;

  /// 操作记录只看审计;调试模式看全部。
  String get _kind => widget.debug ? '' : 'audit';

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
        content: Text(
          widget.debug
              ? '确定清除全部日志(审计+应用)吗?此操作不可恢复。'
              : '确定清除当前筛选下的操作记录吗?此操作不可恢复。',
        ),
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
        title: Text(widget.debug ? '调试日志' : '操作记录'),
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
                    ? Center(child: Text(widget.debug ? '暂无日志' : '暂无操作记录'))
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
                            final time = createdAt == null || createdAt.isEmpty
                                ? ''
                                : formatServerTime(createdAt);
                            if (!widget.debug) {
                              // 操作记录:只显示时间 + 整句中文 action。
                              return ListTile(
                                title: Text(action),
                                subtitle: time.isEmpty ? null : Text(time),
                              );
                            }
                            // 调试模式:类型标签 + 时间 + action + detail(原始 JSON)。
                            final isAudit = '${log['kind']}' == 'audit';
                            return ListTile(
                              leading: _KindTag(isAudit: isAudit),
                              title: Text(action),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (time.isNotEmpty) Text(time),
                                  if (detail != null && detail.isNotEmpty)
                                    Text(
                                      detail,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                        fontFamily: 'monospace',
                                      ),
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

/// 日志类型小色块:审计 = 蓝,应用 = 灰。
class _KindTag extends StatelessWidget {
  const _KindTag({required this.isAudit});

  final bool isAudit;

  @override
  Widget build(BuildContext context) {
    final color = isAudit ? Colors.blue.shade600 : Colors.grey.shade500;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isAudit ? '审计' : '应用',
        style: TextStyle(fontSize: 11, color: color),
      ),
    );
  }
}
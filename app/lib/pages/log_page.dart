import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../platform/file_share.dart';
import '../repository/local_asset_repository.dart';
import '../repository/offline_asset_repository.dart';
import '../storage/secure_store.dart';
import '../utils/time_format.dart';

/// 操作记录页:全部日志(审计+应用,含 detail)查看、CSV 导出、按月清除。
/// 云端优先走 API;断网/未登录/本地模式回退读缓存或本地记录。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<ApiClient> get _api => ApiConfig.client();

  /// 从日志推导有数据的月份(离线/本地无 months 接口时用)。
  List<String> _deriveMonths(List<Map<String, dynamic>> logs) {
    final months = <String>{};
    for (final l in logs) {
      final t = '${l['created_at'] ?? ''}';
      if (t.length >= 7) months.add(t.substring(0, 7));
    }
    return months.toList()..sort();
  }

  /// 按当前月份筛选(离线/本地数据本地过滤)。
  List<Map<String, dynamic>> _filterByMonth(List<Map<String, dynamic>> logs) {
    final m = _month;
    if (m == null || m.isEmpty) return logs;
    return logs.where((l) => '${l['created_at'] ?? ''}'.startsWith(m)).toList();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final jwt = await _store.readJwt();
    final mk = await _store.readMasterKey() ?? '';
    final isLocal = (await _store.readStorageMode()) == 'local';
    try {
      if (isLocal) {
        // 本地模式:读本地操作记录。
        final logs = await LocalAssetRepository(masterKeyB64: mk).listLocalLogs();
        if (!mounted) return;
        setState(() {
          _logs = _filterByMonth(logs);
          _months = _deriveMonths(logs);
          _loading = false;
        });
        return;
      }
      if (jwt == null || jwt.isEmpty) {
        // 未登录:尝试读缓存。
        final logs = await OfflineAssetRepository(
          masterKeyB64: mk,
        ).readLogsFromCache();
        if (!mounted) return;
        setState(() {
          _logs = _filterByMonth(logs);
          _months = _deriveMonths(logs);
          _loading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(logs.isEmpty ? '请先登录或联网' : '离线,显示缓存数据')),
        );
        return;
      }
      // 云端:优先 API。
      try {
        final api = await _api;
        final months = await api.listLogMonths(jwt);
        final logs = await api.listLogs(jwt, kind: 'audit', month: _month ?? '');
        if (!mounted) return;
        setState(() {
          _months = months;
          _logs = logs;
          _loading = false;
        });
      } catch (_) {
        // API 失败(断网):回退缓存。
        final logs = await OfflineAssetRepository(
          masterKeyB64: mk,
        ).readLogsFromCache();
        if (!mounted) return;
        setState(() {
          _logs = _filterByMonth(logs);
          _months = _deriveMonths(logs);
          _loading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('离线,显示缓存数据')),
        );
      }
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

  /// 导出文件名:操作记录-YYYYMMDD-HHMM.csv。
  String get _exportFileName {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '操作记录-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}.csv';
  }

  /// 当前显示数据拼 CSV(离线/本地导出用)。
  String _logsToCsv(List<Map<String, dynamic>> logs) {
    final buf = StringBuffer('类型,时间,操作,详情\n');
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    for (final l in logs) {
      final kind = '${l['kind'] ?? ''}' == 'audit' ? '审计' : '应用';
      buf.writeln('$kind,${esc('${l['created_at'] ?? ''}')},'
          '${esc('${l['action'] ?? ''}')},${esc('${l['detail'] ?? ''}')}');
    }
    return buf.toString();
  }

  Future<void> _export() async {
    final jwt = await _store.readJwt();
    final isLocal = (await _store.readStorageMode()) == 'local';
    // 云端已登录:优先 API 导出;失败回退本地 CSV。
    if (!isLocal && jwt != null && jwt.isNotEmpty) {
      try {
        final csv = await (await _api).exportLogs(
          jwt,
          kind: 'audit',
          month: _month ?? '',
        );
        final ok = await shareTextFile(_exportFileName, csv, '操作记录导出(CSV)');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? '导出成功' : '导出失败,请检查网络后重试')),
        );
        return;
      } catch (_) {
        // 断网:回退到当前显示的数据。
      }
    }
    if (_logs.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂无数据可导出')));
      return;
    }
    final ok = await shareTextFile(
      _exportFileName,
      _logsToCsv(_logs),
      '操作记录导出(CSV)',
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '导出成功' : '导出失败,请检查网络后重试')),
    );
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除操作记录'),
        content: const Text('确定清除操作记录吗?此操作不可恢复。'),
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
        kind: '',
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
        title: const Text('操作记录'),
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
                    ? const Center(child: Text('暂无操作记录'))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.separated(
                          physics: const AlwaysScrollableScrollPhysics(),
                          itemCount: _logs.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final log = _logs[index];
                            final action = log['action']?.toString() ?? '';
                            final createdAt = log['created_at']?.toString();
                            final time = createdAt == null || createdAt.isEmpty
                                ? ''
                                : formatServerTime(createdAt);
                            final isAudit = '${log['kind']}' == 'audit';
                            return ListTile(
                              leading: _KindTag(isAudit: isAudit),
                              title: Text(action),
                              subtitle: time.isEmpty
                                  ? null
                                  : Text(time),
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
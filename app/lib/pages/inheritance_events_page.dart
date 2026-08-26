import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../platform/file_share.dart';
import '../storage/secure_store.dart';
import '../utils/time_format.dart';

/// 继承事件页:年月筛选 + 搜索(API q 参数)+ 固定表头列表 + CSV 导出。
/// 事件永久保留:无删除/清除入口,无保留限制提示。
class InheritanceEventsPage extends StatefulWidget {
  const InheritanceEventsPage({super.key});

  @override
  State<InheritanceEventsPage> createState() => _InheritanceEventsPageState();
}

class _InheritanceEventsPageState extends State<InheritanceEventsPage> {
  final _store = SecureStore();
  final _searchController = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;

  List<Map<String, dynamic>> _events = const [];
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _month; // '2026-08' 或 null = 全部。
  String _q = '';

  /// 每页 50,滚动到底自动加载下一页(offset += 50)。
  static const _pageSize = 50;
  int _offset = 0;

  /// 事件状态色:待领取=橙,已领取=蓝,已撤销=灰。
  static const _statusColors = {
    'pending': Colors.orange,
    'claimed': Colors.blue,
    'reversed': Colors.grey,
  };
  static const _statusLabels = {
    'pending': '待领取',
    'claimed': '已领取',
    'reversed': '已撤销',
  };

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 固定近 12 个月(含当月),倒序。
  List<String> get _monthOptions {
    final now = DateTime.now();
    return [
      for (var i = 0; i < 12; i++)
        '${DateTime(now.year, now.month - i, 1).year}-'
            '${DateTime(now.year, now.month - i, 1).month.toString().padLeft(2, '0')}',
    ];
  }

  /// 滚动接近底部时加载下一页。
  void _onScroll() {
    if (_scroll.position.extentAfter < 200 &&
        !_loadingMore &&
        _offset < _total) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final (items, total) = await (await ApiConfig.client())
          .getInheritanceEvents(
            jwt,
            month: _month ?? '',
            q: _q,
            limit: _pageSize,
            offset: 0,
          );
      if (!mounted) return;
      setState(() {
        _events = items;
        _total = total;
        _offset = items.length;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final (items, total) = await (await ApiConfig.client())
          .getInheritanceEvents(
            jwt,
            month: _month ?? '',
            q: _q,
            limit: _pageSize,
            offset: _offset,
          );
      if (!mounted) return;
      setState(() {
        _events = [..._events, ...items];
        _total = total;
        _offset += items.length;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  /// 导出文件名:继承事件-YYYYMMDD-HHMM.csv。
  String get _exportFileName {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '继承事件-${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}.csv';
  }

  Future<void> _export() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final csv = await (await ApiConfig.client()).exportInheritanceEvents(
        jwt,
        month: _month ?? '',
        q: _q,
      );
      final ok = await shareTextFile(_exportFileName, csv, '继承事件导出(CSV)');
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

  /// 固定表头行(不随列表滚动)。
  Widget _headerRow() {
    final bold = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.bold,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const SizedBox(width: 56, child: Text('状态', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold))),
          Expanded(flex: 3, child: Text('资产', style: bold)),
          Expanded(flex: 2, child: Text('继承人', style: bold)),
          Expanded(flex: 3, child: Text('创建时间', style: bold)),
          Expanded(flex: 3, child: Text('领取时间', style: bold)),
          Expanded(flex: 3, child: Text('撤销时间', style: bold)),
        ],
      ),
    );
  }

  Widget _eventRow(Map<String, dynamic> e) {
    final status = e['status']?.toString() ?? '';
    final color = _statusColors[status] ?? Colors.grey;
    final label = _statusLabels[status] ?? status;
    String time(String? key) {
      final v = e[key]?.toString();
      return (v == null || v.isEmpty) ? '-' : formatServerTime(v);
    }

    final cell = TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: color),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              e['asset_name']?.toString() ?? '未命名',
              style: cell,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              e['inheritor_name']?.toString() ?? '',
              style: cell,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(flex: 3, child: Text(time('created_at'), style: cell)),
          Expanded(flex: 3, child: Text(time('claimed_at'), style: cell)),
          Expanded(flex: 3, child: Text(time('reversed_at'), style: cell)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('继承事件'),
        actions: [
          IconButton(
            tooltip: '导出 CSV',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _export,
          ),
        ],
      ),
      body: Column(
        children: [
          // 年月筛选:固定近 12 个月。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: DropdownButtonFormField<String>(
              initialValue: _month ?? '全部',
              decoration: const InputDecoration(
                labelText: '月份',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: '全部', child: Text('全部')),
                for (final m in _monthOptions)
                  DropdownMenuItem(value: m, child: Text(m)),
              ],
              onChanged: (v) {
                setState(() => _month = v == '全部' ? null : v);
                _load();
              },
            ),
          ),
          // 搜索框:搜资产名/继承人名,调 API q 参数(300ms 防抖)。
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: '搜索资产名或继承人名',
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _q.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _debounce?.cancel();
                          setState(() => _q = '');
                          _load();
                        },
                      ),
              ),
              onChanged: (value) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () {
                  if (!mounted) return;
                  setState(() => _q = value.trim());
                  _load();
                });
              },
            ),
          ),
          // 固定表头 + 滚动列表。
          _headerRow(),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _events.isEmpty
                ? const Center(child: Text('暂无继承事件'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView.separated(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount:
                          _events.length + (_loadingMore ? 1 : 0),
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        if (index >= _events.length) {
                          return const Padding(
                            padding: EdgeInsets.all(12),
                            child: Center(
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          );
                        }
                        return _eventRow(_events[index]);
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
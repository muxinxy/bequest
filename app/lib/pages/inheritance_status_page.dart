import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/inheritance_status.dart';
import '../storage/secure_store.dart';
import '../utils/time_format.dart';

/// 继承状态:当前阶段、升级等级、最近登录与继承事件列表。
class InheritanceStatusPage extends StatefulWidget {
  const InheritanceStatusPage({super.key});

  @override
  State<InheritanceStatusPage> createState() => _InheritanceStatusPageState();
}

class _InheritanceStatusPageState extends State<InheritanceStatusPage> {
  late final Future<ApiClient> _api = ApiConfig.client();
  final _store = SecureStore();

  InheritanceStatus? _status;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final jwt = await _store.readJwt();
      if (jwt == null) throw ApiException('未登录');
      final json = await (await _api).getInheritanceStatus(jwt);
      if (!mounted) return;
      setState(() {
        _status = InheritanceStatus.fromJson(json);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  static String _stageLabel(String? stage) => switch (stage) {
        'inactive' => '未触发',
        'warning' => '提醒中',
        'triggered' => '已触发',
        'claimed' => '已领取',
        'reversed' => '已撤销',
        _ => stage == null || stage.isEmpty ? '未知' : stage,
      };

  static IconData _stageIcon(String? stage) => switch (stage) {
        'inactive' => Icons.shield_outlined,
        'warning' => Icons.warning_amber_rounded,
        'triggered' => Icons.notification_important,
        'claimed' => Icons.key,
        'reversed' => Icons.undo,
        _ => Icons.help_outline,
      };

  static String _eventStatusLabel(String status) => switch (status) {
        'created' => '已创建',
        'claimed' => '已领取',
        'reversed' => '已撤销',
        _ => status,
      };

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('继承状态')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : status == null
              ? const Center(child: Text('暂无数据'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(_stageIcon(status.stage), size: 40),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '当前阶段:${_stageLabel(status.stage)}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '升级等级:${status.escalationLevel ?? 0}'
                                    '${status.lastLoginAt == null ? '' : ' · 最近登录 ${formatServerTime(status.lastLoginAt)}'}',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('继承事件', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (status.events.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text('暂无继承事件'),
                        ),
                      )
                    else
                      ...status.events.map(
                        (e) => Card(
                          child: ListTile(
                            leading: const Icon(Icons.event_note_outlined),
                            title: Text(_eventStatusLabel(e.status)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (e.createdAt != null)
                                  Text('创建:${formatServerTime(e.createdAt)}'),
                                if (e.claimedAt != null)
                                  Text('领取:${formatServerTime(e.claimedAt)}'),
                                if (e.reversedAt != null)
                                  Text('撤销:${formatServerTime(e.reversedAt)}'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    Text('取消继承的三道窗口', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('① 触发前:登录应用即可取消继承。'),
                            SizedBox(height: 8),
                            Text('② 触发后:继承人凭访问码领取密钥,'
                                '在此之前可登录取消。'),
                            SizedBox(height: 8),
                            Text('③ 领取后 72 小时内:登录应用可撤销继承。'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

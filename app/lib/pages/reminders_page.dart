import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../models/reminder.dart';
import '../storage/secure_store.dart';

/// 站内提醒收件箱:未读加粗并带圆点,点击标记已读并查看详情。
class RemindersPage extends StatefulWidget {
  const RemindersPage({super.key});

  @override
  State<RemindersPage> createState() => _RemindersPageState();
}

class _RemindersPageState extends State<RemindersPage> {
  late final Future<ApiClient> _api = ApiConfig.client();
  final _store = SecureStore();

  List<Reminder> _reminders = const [];
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
      final list = await (await _api).listReminders(jwt);
      if (!mounted) return;
      setState(() {
        _reminders = list.map(Reminder.fromJson).toList(growable: false);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  Future<void> _openReminder(Reminder reminder) async {
    if (reminder.isUnread) {
      try {
        final jwt = await _store.readJwt();
        if (jwt == null) throw ApiException('未登录');
        await (await _api).markReminderRead(jwt, reminder.id);
        if (!mounted) return;
        setState(() {
          _reminders = [
            for (final r in _reminders)
              r.id == reminder.id
                  ? Reminder(
                      id: r.id,
                      type: r.type,
                      title: r.title,
                      body: r.body,
                      status: 'read',
                      createdAt: r.createdAt,
                    )
                  : r,
          ];
        });
      } catch (_) {
        // 标记失败不阻塞查看详情。
      }
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(reminder.title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_typeLabel(reminder.type)),
              const SizedBox(height: 12),
              Text(reminder.body.isEmpty ? '(无内容)' : reminder.body),
              if (reminder.createdAt != null) ...[
                const SizedBox(height: 12),
                Text(
                  reminder.createdAt!,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  static String _typeLabel(String type) => switch (type) {
        'expiry' => '到期提醒',
        'escalation' => '继承升级',
        'inheritance' => '继承事件',
        _ => type,
      };

  static IconData _typeIcon(String type) => switch (type) {
        'expiry' => Icons.alarm,
        'escalation' => Icons.warning_amber_rounded,
        'inheritance' => Icons.menu_book_outlined,
        _ => Icons.notifications_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final unreadCount = _reminders.where((r) => r.isUnread).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(unreadCount == 0 ? '提醒' : '提醒($unreadCount)'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _reminders.isEmpty
              ? const Center(child: Text('暂无提醒'))
              : ListView.separated(
                  itemCount: _reminders.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final reminder = _reminders[index];
                    return ListTile(
                      leading: Icon(_typeIcon(reminder.type)),
                      title: Row(
                        children: [
                          if (reminder.isUnread) ...[
                            Container(
                              width: 8,
                              height: 8,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.error,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                          Expanded(
                            child: Text(
                              reminder.title,
                              style: reminder.isUnread
                                  ? const TextStyle(fontWeight: FontWeight.bold)
                                  : null,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        '${_typeLabel(reminder.type)}'
                        '${reminder.createdAt == null ? '' : ' · ${reminder.createdAt}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _openReminder(reminder),
                    );
                  },
                ),
    );
  }
}

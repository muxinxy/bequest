import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../storage/secure_store.dart';

/// 审计日志:只读展示后端记录的操作流水。
class AuditPage extends StatefulWidget {
  const AuditPage({super.key});

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  late final Future<ApiClient> _api = ApiConfig.client();
  final _store = SecureStore();

  List<Map<String, dynamic>> _logs = const [];
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
      final logs = await (await _api).listAuditLog(jwt);
      if (!mounted) return;
      setState(() {
        _logs = logs;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('加载失败,请检查网络后重试')));
      Navigator.of(context).pop();
    }
  }

  static String _actionLabel(String action) => switch (action) {
        'login_reset' => '登录重置/继承流程',
        'inheritance_triggered' => '继承触发',
        'inheritance_claimed' => '继承领取',
        'inheritance_created' => '创建继承',
        _ => action,
      };

  static String _actorLabel(String actor) {
    const prefix = 'inheritor:';
    if (actor == 'owner') return '号主';
    if (actor == 'system') return '系统';
    if (actor.startsWith(prefix)) {
      return '继承人#${actor.substring(prefix.length)}';
    }
    return actor;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('审计日志')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
              ? const Center(child: Text('暂无审计日志'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: _logs.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final log = _logs[index];
                      final action = log['action']?.toString() ?? '';
                      final actor = log['actor']?.toString() ?? '';
                      final detail = log['detail']?.toString();
                      final createdAt = log['created_at']?.toString();
                      return ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(_actionLabel(action)),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (detail != null && detail.isNotEmpty)
                              Text(detail),
                            Text(
                              '${_actorLabel(actor)}'
                              '${createdAt == null || createdAt.isEmpty ? '' : ' · $createdAt'}',
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

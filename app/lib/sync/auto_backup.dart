import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';

import '../storage/secure_store.dart';
import 'backup.dart';
import 'backup_naming.dart';
import 'local_vault.dart';
import 'sync_provider.dart';

/// 自动备份配置。
const kAutoBackupIntervals = <String, Duration?>{
  'off': null,
  '1m': Duration(minutes: 1),
  '5m': Duration(minutes: 5),
  '15m': Duration(minutes: 15),
  '30m': Duration(minutes: 30),
  '1h': Duration(hours: 1),
  '2h': Duration(hours: 2),
  '6h': Duration(hours: 6),
  '12h': Duration(hours: 12),
  '24h': Duration(hours: 24),
  // 特殊值:开应用时 / 退出应用时,不由定时器驱动。
  'on_open': null,
  'on_exit': null,
};
const kAutoBackupIntervalLabels = <String, String>{
  'off': '不自动备份',
  '1m': '每 1 分钟',
  '5m': '每 5 分钟',
  '15m': '每 15 分钟',
  '30m': '每 30 分钟',
  '1h': '每 1 小时',
  '2h': '每 2 小时',
  '6h': '每 6 小时',
  '12h': '每 12 小时',
  '24h': '每 24 小时',
  'on_open': '打开应用时',
  'on_exit': '退出应用时',
};
const kAutoBackupMaxCounts = <int>[1, 3, 5, 10, 20, 50];

/// 自动备份调度:按配置的间隔定时触发,并响应"开应用/退应用"事件。
/// 单实例,由 main() 启动。备份失败仅记日志,不打断正常流程。
class AutoBackupScheduler {
  AutoBackupScheduler._();

  static final AutoBackupScheduler instance = AutoBackupScheduler._();

  final _store = SecureStore();
  Timer? _timer;
  bool _listening = false;

  /// 读取配置中的备份间隔键('off'|'1m'|...|'on_open'|'on_exit')。
  static String intervalKeyOf(Map<String, dynamic> cfg) =>
      cfg['auto_backup_interval']?.toString() ?? 'off';

  static int maxCountOf(Map<String, dynamic> cfg) {
    final v = int.tryParse(cfg['auto_backup_max']?.toString() ?? '') ?? 3;
    return kAutoBackupMaxCounts.contains(v) ? v : 3;
  }

  /// 启动:监听应用生命周期 + 按间隔启动定时器。
  void start() {
    if (_listening) return;
    _listening = true;
    WidgetsBinding.instance.addObserver(_LifecycleObserver());
    _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = null;
    unawaited(_applyConfig());
  }

  Future<void> _applyConfig() async {
    final cfg = await _readConfig();
    final key = intervalKeyOf(cfg);
    final duration = kAutoBackupIntervals[key];
    if (duration == null) return; // off / on_open / on_exit 无定时器
    _timer = Timer.periodic(duration, (_) => unawaited(runNow()));
  }

  Future<Map<String, dynamic>> _readConfig() async {
    final raw = await _store.readSyncConfig();
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }

  /// 配置变更后重启调度器(同步设置页保存时调用)。
  Future<void> onConfigChanged() async {
    _restartTimer();
    final cfg = await _readConfig();
    if (intervalKeyOf(cfg) == 'on_open') {
      // 设置页保存即视为"打开应用"场景?否——on_open 只在启动时触发一次。
    }
  }

  /// 应用进入前台(打开应用时触发一次)。
  Future<void> onAppResumed() async {
    final cfg = await _readConfig();
    if (intervalKeyOf(cfg) == 'on_open') {
      await runNow();
    }
  }

  /// 应用退到后台(退出应用时触发一次)。
  Future<void> onAppPaused() async {
    final cfg = await _readConfig();
    if (intervalKeyOf(cfg) == 'on_exit') {
      await runNow();
    }
  }

  /// 立即执行一次备份 + 轮转(超过最大数量删最旧)。
  Future<void> runNow() async {
    try {
      final cfg = await _readConfig();
      final provider = syncProviderFromConfig(cfg);
      if (provider == null) return; // 未配置同步目标
      final masterKey = await _store.readMasterKey();
      if (masterKey == null || masterKey.isEmpty) return;
      final jwt = await _store.readJwt();
      final backupJson = await buildBackupJson(jwt, null, masterKey);
      // 复用同步设置页的时间戳格式。
      final now = DateTime.now();
      String pad(int n) => n.toString().padLeft(2, '0');
      final timestamp = '${now.year}${pad(now.month)}${pad(now.day)}'
          '_${pad(now.hour)}${pad(now.minute)}${pad(now.second)}';
      // 账户名:优先配置里存的(手动同步时写入),否则实时取
      // (本地模式 = 当前激活账户名)。
      final username = cfg['username']?.toString().isNotEmpty == true
          ? cfg['username'].toString()
          : await currentAccountName(store: _store);
      final device = cfg['device_name']?.toString() ?? await deviceName();
      final name = buildBackupFileName(
        username: username,
        deviceName: device,
        timestamp: timestamp,
      );
      // 主密钥加密为上传负载(与手动同步一致),盐随负载上传供跨设备恢复。
      final salt =
          await LocalVault().readSalt(masterKey) ?? await _store.readMasterSalt();
      final payload = await buildSyncPayload(backupJson, masterKey, salt: salt);
      await provider.upload(name, jsonEncode(payload));
      await _rotate(provider);
    } catch (e) {
      // 自动备份失败不打扰用户,仅记日志。
      assert(() {
        // ignore: avoid_print
        print('auto backup failed: $e');
        return true;
      }());
    }
  }

  /// 轮转:列出备份,超过 maxCount 删最旧。
  Future<void> _rotate(SyncProvider provider) async {
    final cfg = await _readConfig();
    final maxCount = maxCountOf(cfg);
    if (maxCount <= 0) return;
    try {
      final files = await provider.listFiles();
      if (files.length <= maxCount) return;
      for (final f in files.skip(maxCount)) {
        try {
          await provider.delete(f.name);
        } catch (_) {
          // 单条删除失败不阻断。
        }
      }
    } catch (_) {
      // 列不出列表时跳过轮转。
    }
  }
}

/// 生命周期观察:resumed → on_open 备份;paused → on_exit 备份。
class _LifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(AutoBackupScheduler.instance.onAppResumed());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(AutoBackupScheduler.instance.onAppPaused());
    }
  }
}

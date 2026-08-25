import 'dart:async';

import 'package:flutter/material.dart';

import 'logger.dart';
import 'pages/app_lock_screen.dart';
import 'pages/login_page.dart';
import 'storage/secure_store.dart';
import 'app_lock_policy.dart';
import 'storage/secure_storage_io.dart'
    if (dart.library.js_interop) 'storage/secure_storage_web.dart'
    as secure_storage;
import 'sync/auto_backup.dart';

void main() {
  // 必须在访问 WidgetsBinding/runApp 前初始化 binding;
  // 自动备份调度器要挂生命周期观察者,晚于此处会空指针崩溃(web 白屏)。
  WidgetsFlutterBinding.ensureInitialized();
  // Web 下 secure storage 降级 localStorage(官方 WebCrypto 在 HTTP 局域网
  // 不可用,会导致注册/登录写存储抛异常),必须在首次读写前替换。
  secure_storage.initPlatformSecureStorage();
  Logger.instance.d('app start');
  // 自动备份调度:按配置间隔定时 + 开应用/退应用触发。
  AutoBackupScheduler.instance.start();
  runApp(const BequestApp());
}

/// 全局导航 key:供 LockGate 等 MaterialApp.builder 之上的组件操作主 Navigator
/// (锁屏在独立 Navigator 覆盖层,无法用自身 context 导航主栈)。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class BequestApp extends StatefulWidget {
  const BequestApp({super.key});

  /// 设置页切换主题后通知全局刷新。
  static void notifyThemeChanged() => _BequestAppState._instance?.reloadTheme();

  @override
  State<BequestApp> createState() => _BequestAppState();
}

class _BequestAppState extends State<BequestApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    try {
      final mode = await SecureStore().readThemeMode();
      if (!mounted) return;
      setState(() {
        _themeMode = switch (mode) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
      });
    } catch (_) {
      // 读取失败保持默认(跟随系统)。
    }
  }

  /// 重新加载主题(设置页切换后调用)。
  void reloadTheme() => _loadTheme();

  static _BequestAppState? _instance;

  @override
  Widget build(BuildContext context) {
    _instance = this;
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: '托孤',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        fontFamily: 'NotoSansSC',
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
        fontFamily: 'NotoSansSC',
      ),
      themeMode: _themeMode,
      builder: (context, child) =>
          LockGate(child: child ?? const SizedBox.shrink()),
      home: const LoginPage(),
    );
  }
}

/// 应用锁门:包裹整个 Navigator,锁定时用锁屏覆盖,解锁后恢复。
///
/// 用 Stack 而非条件替换,保证 Navigator 状态(当前页面)在锁定期间不丢失。
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  /// 手动锁定:立即锁定应用(重新进入需解锁)。
  /// 不读凭据判断——锁屏自身处理:无任何解锁方式时自动放行(见
  /// AppLockScreen),有凭据则正常校验。web 端 flutter_secure_storage 依赖
  /// WebCrypto(仅 HTTPS/localhost 可用),局域网 HTTP 下读取会抛异常,
  /// 因此不能以"读到凭据"作为锁定前提。
  static void lockNow() => _LockGateState._instance?.lockNow();

  /// 锁屏「跳过」:退出当前模式回登录页(清理逻辑在 AppLockScreen 完成,
  /// 这里负责解除锁定遮罩并清空主 Navigator 栈回登录页)。
  /// 锁屏位于独立 Navigator 覆盖层,无法直接操作主 Navigator,
  /// 必须由 LockGate(主 Navigator 祖先)执行导航。
  static void exitToLogin() => _LockGateState._instance?.exitToLogin();

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  final _store = SecureStore();
  late final AppLifecycleListener _lifecycleListener;

  bool _checked = false;
  bool _locked = false;
  Timer? _lockTimer;

  /// 手动锁定入口:主页"锁定"按钮经此触发(见 [LockGate.lockNow])。
  /// ponytail: 单实例应用,静态指针够用。
  static _LockGateState? _instance;

  @override
  void initState() {
    super.initState();
    _instance = this;
    _lifecycleListener = AppLifecycleListener(onStateChange: _onLifecycleState);
    _init();
  }

  @override
  void dispose() {
    if (_instance == this) _instance = null;
    _lockTimer?.cancel();
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    bool locked = false;
    try {
      final jwt = await _store.readJwt();
      final mk = await _store.readMasterKey();
      final enabled = await _store.readLockEnabled();
      // 本地模式无 jwt 但有主密钥,同样要锁;只按 jwt 判断会漏锁。
      locked = shouldLockOnColdStart(
        lockEnabled: enabled,
        hasCredential: jwt != null || (mk != null && mk.isNotEmpty),
      );
    } catch (_) {
      locked = false;
    }
    if (mounted) {
      setState(() {
        _checked = true;
        _locked = locked;
      });
    }
  }

  void _onLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _handleBackground();
    } else if (state == AppLifecycleState.resumed) {
      // 超时模式下提前回到前台:取消计时,保持解锁。
      _cancelLockTimer();
    }
  }

  /// 进入后台:退出时锁定 → 立即锁;退出且超时锁定 → 启动 N 分钟计时,到时再锁。
  Future<void> _handleBackground() async {
    if (_locked) return;
    try {
      final jwt = await _store.readJwt();
      final mk = await _store.readMasterKey();
      final enabled = await _store.readLockEnabled();
      if (!shouldLockOnColdStart(
            lockEnabled: enabled,
            hasCredential: jwt != null || (mk != null && mk.isNotEmpty),
          ) ||
          !mounted) {
        return;
      }
      final timing = await _store.readLockTiming();
      if (timing == 'timeout') {
        final minutes = await _store.readLockTimeoutMinutes();
        _cancelLockTimer();
        _lockTimer = Timer(Duration(minutes: minutes), _lockNow);
      } else {
        await _lockNow();
      }
    } catch (_) {
      // 读取失败保持当前状态。
    }
  }

  void _cancelLockTimer() {
    _lockTimer?.cancel();
    _lockTimer = null;
  }

  Future<void> _lockNow() async {
    _cancelLockTimer();
    if (_locked) return;
    try {
      final jwt = await _store.readJwt();
      final mk = await _store.readMasterKey();
      final enabled = await _store.readLockEnabled();
      if (shouldLockOnColdStart(
            lockEnabled: enabled,
            hasCredential: jwt != null || (mk != null && mk.isNotEmpty),
          ) &&
          mounted) {
        setState(() => _locked = true);
      }
    } catch (_) {
      // 读取失败保持当前状态。
    }
  }

  /// 手动锁定:直接锁定。锁屏自身会校验解锁方式——有凭据走校验,
  /// 无任何解锁方式自动放行,不会锁死。
  Future<void> lockNow() async {
    if (_locked) return;
    if (mounted) setState(() => _locked = true);
  }

  /// 锁屏「跳过」:解除锁定遮罩,清空主 Navigator 栈回登录页。
  void exitToLogin() {
    if (!mounted) return;
    setState(() => _locked = false);
    appNavigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_checked && _locked)
          Positioned.fill(
            // 锁屏位于 MaterialApp.builder,与主 Navigator 是兄弟节点而非后代,
            // showDialog 会抛 "no Navigator" 异常(用主密码解锁因此完全无反应)。
            // 包一层独立 Navigator 提供对话框宿主,且不干扰主路由栈;
            // HeroControllerScope.none 避免与主 Navigator 争用同一个 HeroController。
            child: HeroControllerScope.none(
              child: Navigator(
                onGenerateRoute: (settings) => MaterialPageRoute<void>(
                  settings: settings,
                  builder: (_) => AppLockScreen(
                    onUnlocked: () => setState(() => _locked = false),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

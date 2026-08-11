import 'dart:async';

import 'package:flutter/material.dart';

import 'logger.dart';
import 'pages/app_lock_screen.dart';
import 'pages/login_page.dart';
import 'storage/secure_store.dart';
import 'app_lock_policy.dart';

void main() {
  Logger.instance.d('app start');
  runApp(const BequestApp());
}

class BequestApp extends StatelessWidget {
  const BequestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '托孤',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
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

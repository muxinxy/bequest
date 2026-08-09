import 'package:flutter/material.dart';

import 'pages/app_lock_screen.dart';
import 'pages/login_page.dart';
import 'storage/secure_store.dart';

void main() {
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

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  final _store = SecureStore();
  late final AppLifecycleListener _lifecycleListener;

  bool _checked = false;
  bool _locked = false;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onStateChange: _onLifecycleState);
    _init();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    bool locked = false;
    try {
      final jwt = await _store.readJwt();
      final enabled = await _store.readLockEnabled();
      locked = enabled && jwt != null;
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
    // 应用进入后台即锁定,回到前台需解锁。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _lockNow();
    }
  }

  Future<void> _lockNow() async {
    if (_locked || !_checked) return;
    try {
      final jwt = await _store.readJwt();
      final enabled = await _store.readLockEnabled();
      if (enabled && jwt != null && mounted) {
        setState(() => _locked = true);
      }
    } catch (_) {
      // 读取失败保持当前状态。
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_checked && _locked)
          Positioned.fill(
            child: AppLockScreen(
              onUnlocked: () => setState(() => _locked = false),
            ),
          ),
      ],
    );
  }
}

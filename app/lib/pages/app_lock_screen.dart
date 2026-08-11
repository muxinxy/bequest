import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

import '../crypto/attempt_guard.dart';
import '../crypto/master_password.dart';
import '../crypto/pattern_hash.dart';
import '../crypto/pin_hash.dart';
import '../logger.dart';
import '../storage/secure_store.dart';
import '../widgets/pattern_lock.dart';

/// 锁屏:按已配置的解锁方式展示——图案、PIN、生物识别(可同时存在)。
/// 解锁成功后回调 [onUnlocked]。
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key, required this.onUnlocked});

  final VoidCallback onUnlocked;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _store = SecureStore();
  final _auth = LocalAuthentication();
  final _pinController = TextEditingController();

  /// 应用锁失败限流:连续 5 次错误 → 锁定 60 秒。
  late final AttemptGuard _lockGuard = AttemptGuard(
    store: _store,
    prefix: 'lock',
  );
  /// 主密码解锁独立限流(主密码是最强凭据,可绕过 PIN/图案/生物识别)。
  late final AttemptGuard _masterGuard = AttemptGuard(
    store: _store,
    prefix: 'master',
  );
  Timer? _lockTimer;
  int _lockSeconds = 0;
  /// 主密码独立限流的剩余秒数(与 PIN/图案的 [_lockSeconds] 分开,
  /// 主密码被限流不应影响其他解锁方式)。
  Timer? _masterLockTimer;
  int _masterLockSeconds = 0;

  bool _biometricEnabled = false;
  bool _hasPin = false;
  bool _hasPattern = false;
  bool _hasMasterKey = false;
  String _patternSalt = '';
  String _patternHash = '';
  bool _verifying = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _lockTimer?.cancel();
    _masterLockTimer?.cancel();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final biometricEnabled = await _store.readLockBiometric();
      final hasPin = (await _store.readPinHash()) != null;
      final masterKey = await _store.readMasterKey();
      final patternHash = await _store.readPatternHash();
      final patternSalt = await _store.readPatternSalt();
      if (mounted) {
        setState(() {
          _hasPin = hasPin;
          _hasPattern = patternHash != null && patternSalt != null;
          _hasMasterKey = masterKey != null && masterKey.isNotEmpty;
          _patternHash = patternHash ?? '';
          _patternSalt = patternSalt ?? '';
          _biometricEnabled = biometricEnabled;
        });
      }
      if (_biometricEnabled) {
        await _tryBiometric();
      }
      // 未配置任何可校验方式(存储被清空等):视为解锁,避免被锁死。
      // 生物识别可用(含校验失败)时不自动解锁,防止失败后静默放行。
      if (mounted && !_hasPin && !_hasPattern && !_biometricEnabled) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onUnlocked();
        });
      }
      // 上次锁定未到期(如进程被杀后重启):继续倒计时。
      if (mounted && await _lockGuard.checkLocked()) {
        await _startLockCountdown();
      }
      // 主密码被其他入口(导出/导入/修改主密码/恢复)限流时,锁屏也要可见提示。
      if (mounted && await _masterGuard.checkLocked()) {
        await _startMasterLockCountdown();
      }
    } catch (_) {
      // 模拟器/测试环境无生物识别能力,静默降级。
    }
  }

  Future<void> _tryBiometric() async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      // 设备未录入任何生物识别:明确提示,不弹系统框。
      List<BiometricType> available;
      try {
        available = await _auth.getAvailableBiometrics();
      } catch (_) {
        available = const [];
      }
      if (available.isEmpty) {
        if (mounted) {
          setState(() => _error = '设备未录入指纹或人脸,请先在系统设置中添加');
        }
        return;
      }
      final ok = await _auth.authenticate(
        localizedReason: '请验证生物识别以解锁',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: false,
        ),
      );
      if (ok && mounted) widget.onUnlocked();
      // 返回 false = 用户取消,不提示错误、不计数。
    } catch (e) {
      // 用户主动取消(如点系统返回)不算失败,静默。
      if (e is PlatformException &&
          (e.code == 'AppCanceled' ||
              e.code == 'UserCanceled' ||
              e.code == 'SystemCanceled')) {
        return;
      }
      Logger.instance.e('biometric unlock failed: $e');
      if (mounted) setState(() => _error = _biometricErrorMessage(e));
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  /// 把 local_auth 的 PlatformException code 映射为中文原因。
  String _biometricErrorMessage(Object error) {
    if (error is PlatformException) {
      switch (error.code) {
        case 'NotEnrolled':
          return '未录入指纹/人脸,请在系统设置中添加';
        case 'NotAvailable':
          return '设备不支持生物识别';
        case 'LockedOut':
          return '尝试次数过多,系统已暂时锁定生物识别,请稍后再试或用其他方式解锁';
        case 'PermanentlyLocked':
          return '生物识别已被系统永久锁定,请用其他方式解锁';
      }
    }
    return '生物识别验证失败,请重试或用其他方式解锁';
  }

  Future<void> _unlockWithPin() async {
    if (await _lockGuard.checkLocked()) {
      await _startLockCountdown();
      return;
    }
    final pin = _pinController.text;
    if (pin.isEmpty) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final salt = await _store.readPinSalt();
      final hash = await _store.readPinHash();
      if (hashPin(pin, salt ?? '') == hash) {
        await _lockGuard.recordSuccess();
        if (mounted) widget.onUnlocked();
      } else {
        await _recordWrongAttempt();
        // 进入锁定时由倒计时文案提示,不再叠加"错误"提示。
        if (mounted && _lockSeconds == 0) {
          setState(() => _error = 'PIN 码错误,请重试');
        }
        _pinController.clear();
      }
    } catch (_) {
      if (mounted) setState(() => _error = '解锁失败,请重试');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _unlockWithPattern(List<int> dots) async {
    if (await _lockGuard.checkLocked()) {
      await _startLockCountdown();
      return;
    }
    // 任何未通过校验的尝试(含 <4 点短图案、盐/哈希缺失的损坏状态)都计失败,
    // 与 PIN 路径一致;否则解锁并清零计数。
    if (shouldRecordPatternFailure(
      salt: _patternSalt,
      hash: _patternHash,
      dots: dots,
    )) {
      await _recordWrongAttempt();
      // 进入锁定时由倒计时文案提示,不再叠加"错误"提示。
      if (mounted && _lockSeconds == 0) {
        setState(() => _error = '图案错误,请重试');
      }
    } else {
      await _lockGuard.recordSuccess();
      if (mounted) widget.onUnlocked();
    }
  }

  /// 用主密码解锁:主密码是最强凭据,验证通过即绕过 PIN/图案/生物识别。
  Future<void> _unlockWithMasterPassword() async {
    if (_verifying) return;
    final password = await showMasterPasswordDialog(context);
    if (password == null || password.isEmpty) return;
    if (!mounted) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final ok = await masterPasswordUnlock(
        store: _store,
        guard: _masterGuard,
        password: password,
      );
      if (!mounted) return;
      if (ok) {
        // 同时清零应用锁(PIN/图案)计数,与正常解锁一致。
        await _lockGuard.recordSuccess();
        widget.onUnlocked();
        return;
      }
      // 未通过:限流中给持久倒计时提示,否则提示密码错误(避免仅一闪而过的
      // snackbar 被忽略——这是"用主密码解锁没反应"的常见误判来源)。
      if (await _masterGuard.checkLocked()) {
        await _startMasterLockCountdown();
      } else {
        setState(() => _error = '主密码错误,请重试');
      }
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  /// 记录一次失败;达到阈值后进入锁定并启动倒计时。
  Future<void> _recordWrongAttempt() async {
    await _lockGuard.recordFailure();
    await _startLockCountdown();
  }

  /// 显示剩余锁定秒数并每秒刷新;到期后重新启用输入。
  Future<void> _startLockCountdown() async {
    if (_lockTimer != null) return;
    final seconds = await _lockGuard.remainingSeconds();
    if (seconds <= 0) return;
    if (!mounted) return;
    setState(() {
      _lockSeconds = seconds;
      _error = null;
    });
    _lockTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final remaining = await _lockGuard.remainingSeconds();
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (remaining <= 0) {
        timer.cancel();
        _lockTimer = null;
        setState(() => _lockSeconds = 0);
      } else {
        setState(() => _lockSeconds = remaining);
      }
    });
  }

  /// 显示主密码限流的剩余秒数并每秒刷新;到期后自动清零。
  /// 与 [_startLockCountdown] 分开:主密码被限流不冻结 PIN/图案输入。
  Future<void> _startMasterLockCountdown() async {
    if (_masterLockTimer != null) return;
    final seconds = await _masterGuard.remainingSeconds();
    if (seconds <= 0) return;
    if (!mounted) return;
    setState(() => _masterLockSeconds = seconds);
    _masterLockTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      final remaining = await _masterGuard.remainingSeconds();
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (remaining <= 0) {
        timer.cancel();
        _masterLockTimer = null;
        setState(() => _masterLockSeconds = 0);
      } else {
        setState(() => _masterLockSeconds = remaining);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.lock_outline, size: 72),
                const SizedBox(height: 16),
                Text(
                  '应用已锁定',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  _hasPattern ? '请绘制图案解锁' : '请输入 PIN 码解锁',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
                if (_lockSeconds > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '尝试次数过多,请等待 $_lockSeconds 秒后重试',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (_hasPattern) ...[
                  const SizedBox(height: 16),
                  Center(
                    child: IgnorePointer(
                      ignoring: _lockSeconds > 0,
                      child: SizedBox(
                        width: 260,
                        height: 260,
                        child: PatternLock(onCompleted: _unlockWithPattern),
                      ),
                    ),
                  ),
                ],
                if (_hasPin) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pinController,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    enabled: _lockSeconds == 0,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 24, letterSpacing: 12),
                    decoration: InputDecoration(
                      counterText: '',
                      border: const OutlineInputBorder(),
                      errorText: _error,
                    ),
                    onSubmitted: (_) => _unlockWithPin(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: (_verifying || _lockSeconds > 0)
                        ? null
                        : _unlockWithPin,
                    child: _verifying
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('解锁'),
                  ),
                ],
                if (_hasPattern && !_hasPin && _error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (_biometricEnabled) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: (_verifying || _lockSeconds > 0)
                        ? null
                        : _tryBiometric,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('生物识别解锁'),
                  ),
                ],
                if (_hasMasterKey) ...[
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: _verifying ? null : _unlockWithMasterPassword,
                    child: const Text('用主密码解锁'),
                  ),
                  if (_masterLockSeconds > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '主密码尝试次数过多,请等待 $_masterLockSeconds 秒后重试',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

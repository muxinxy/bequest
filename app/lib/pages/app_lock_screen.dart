import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../crypto/pattern_hash.dart';
import '../crypto/pin_hash.dart';
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

  bool _biometricAvailable = false;
  bool _hasPin = false;
  bool _hasPattern = false;
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
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final biometric = await _store.readLockBiometric();
      final hasPin = (await _store.readPinHash()) != null;
      final patternHash = await _store.readPatternHash();
      final patternSalt = await _store.readPatternSalt();
      var biometricAvailable = false;
      if (biometric) {
        final canCheck = await _auth.canCheckBiometrics;
        final supported = await _auth.isDeviceSupported();
        biometricAvailable = canCheck && supported;
      }
      if (mounted) {
        setState(() {
          _hasPin = hasPin;
          _hasPattern = patternHash != null && patternSalt != null;
          _patternHash = patternHash ?? '';
          _patternSalt = patternSalt ?? '';
          _biometricAvailable = biometricAvailable;
        });
      }
      if (biometricAvailable) {
        await _tryBiometric();
      }
      // 未配置任何可校验方式(存储被清空等):视为解锁,避免被锁死。
      // 生物识别可用(含校验失败)时不自动解锁,防止失败后静默放行。
      if (mounted && !_hasPin && !_hasPattern && !biometricAvailable) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onUnlocked();
        });
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
      final ok = await _auth.authenticate(
        localizedReason: '请验证生物识别以解锁',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: false,
        ),
      );
      if (ok && mounted) widget.onUnlocked();
    } catch (_) {
      if (mounted) setState(() => _error = '生物识别失败,请使用其他方式解锁');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  Future<void> _unlockWithPin() async {
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
        if (mounted) widget.onUnlocked();
      } else {
        if (mounted) {
          setState(() => _error = 'PIN 码错误,请重试');
          _pinController.clear();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _error = '解锁失败,请重试');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  void _unlockWithPattern(List<int> dots) {
    if (dots.length < 4) {
      setState(() => _error = '图案错误,请重试');
      return;
    }
    if (verifyPattern(dots, _patternSalt, _patternHash)) {
      widget.onUnlocked();
    } else {
      setState(() => _error = '图案错误,请重试');
    }
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
                if (_hasPattern) ...[
                  const SizedBox(height: 16),
                  Center(
                    child: SizedBox(
                      width: 260,
                      height: 260,
                      child: PatternLock(onCompleted: _unlockWithPattern),
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
                    onPressed: _verifying ? null : _unlockWithPin,
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
                if (_biometricAvailable) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _verifying ? null : _tryBiometric,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('生物识别解锁'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

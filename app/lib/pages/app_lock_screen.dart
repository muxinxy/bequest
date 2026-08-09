import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../crypto/pin_hash.dart';
import '../storage/secure_store.dart';

/// 锁屏:PIN 解锁,启用生物识别时提供指纹/面容解锁按钮。
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
      if (biometric) {
        final canCheck = await _auth.canCheckBiometrics;
        final supported = await _auth.isDeviceSupported();
        if (canCheck && supported && mounted) {
          setState(() => _biometricAvailable = true);
          await _tryBiometric();
        }
      }
    } catch (_) {
      // 模拟器/测试环境无生物识别能力,静默降级为仅 PIN。
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
      if (mounted) setState(() => _error = '生物识别失败,请使用 PIN 解锁');
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
      if (salt == null || hash == null) {
        // 无 PIN 记录(存储被清空):视为解锁。
        if (mounted) widget.onUnlocked();
        return;
      }
      if (hashPin(pin, salt) == hash) {
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
                const Text(
                  '请输入 PIN 码解锁',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
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

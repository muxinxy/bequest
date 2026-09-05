import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import '../crypto/key_derivation.dart';
import '../crypto/pattern_hash.dart';
import '../crypto/pin_hash.dart';
import '../l10n/app_l10n.dart';
import '../storage/secure_store.dart';
import '../widgets/pattern_lock.dart';

/// 应用锁:解锁方式(PIN/图案/生物识别)、锁定时机(退出即锁/退出且超时锁)。
class AppLockSetupPage extends StatefulWidget {
  const AppLockSetupPage({super.key});

  @override
  State<AppLockSetupPage> createState() => _AppLockSetupPageState();
}

class _AppLockSetupPageState extends State<AppLockSetupPage> {
  final _formKey = GlobalKey<FormState>();
  final _store = SecureStore();

  final _pinController = TextEditingController();
  final _confirmController = TextEditingController();
  final _timeoutController = TextEditingController();

  String _timing = 'exit';
  bool _lockEnabled = false;
  bool _biometricEnabled = false;
  List<BiometricType> _availableBiometrics = [];
  bool _hasPin = false;
  bool _hasPattern = false;
  List<int>? _newPattern;
  bool _clearPattern = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pinController.dispose();
    _confirmController.dispose();
    _timeoutController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final lockEnabled = await _store.readLockEnabled();
      final biometricEnabled = await _store.readLockBiometric();
      final timing = await _store.readLockTiming();
      final timeout = await _store.readLockTimeoutMinutes();
      final hasPin = (await _store.readPinHash()) != null;
      final hasPattern = (await _store.readPatternHash()) != null;
      // 查询设备实际注册的生物识别,用于支持提示。
      var available = <BiometricType>[];
      // ponytail: web 无 local_auth 实现,直接按无生物识别处理。
      if (!kIsWeb) {
        try {
          final auth = LocalAuthentication();
          if (await auth.isDeviceSupported() && await auth.canCheckBiometrics) {
            available = await auth.getAvailableBiometrics();
          }
        } catch (_) {
          available = [];
        }
      }
      if (mounted) {
        setState(() {
          _lockEnabled = lockEnabled;
          _biometricEnabled = biometricEnabled;
          _availableBiometrics = available;
          _timing = timing;
          _hasPin = hasPin;
          _hasPattern = hasPattern;
          _timeoutController.text = '$timeout';
        });
      }
    } catch (_) {
      // 读取失败按默认处理。
    }
  }

  /// 设备可用类别的中文描述;iris 归入人脸类。
  String _supportText() {
    if (_availableBiometrics.isEmpty) {
      return L10n.tr('当前设备未检测到生物识别');
    }
    final labels = _availableBiometrics.map((b) => switch (b) {
      BiometricType.fingerprint => L10n.tr('指纹'),
      BiometricType.face || BiometricType.iris => L10n.tr('人脸'),
      BiometricType.strong => L10n.tr('指纹(强)'),
      BiometricType.weak => L10n.tr('弱生物识别'),
    }).toSet();
    return L10n.trp('当前设备支持: {labels}', {'labels': labels.join(' / ')});
  }

  /// 设置/重设图案:两次绘制一致才写入(此时只存内存,点保存落盘)。
  Future<void> _setupPattern() async {
    final pattern = await showDialog<List<int>>(
      context: context,
      builder: (context) => const _PatternSetupDialog(),
    );
    if (pattern != null && mounted) {
      setState(() {
        _newPattern = pattern;
        _clearPattern = false;
      });
    }
  }

  String? _validatePin(String? value) {
    if (value == null || value.isEmpty) return null; // 留空 = 不改动现有 PIN
    if (!RegExp(r'^\d{4,6}$').hasMatch(value)) {
      return L10n.tr('PIN 码需为 4-6 位数字');
    }
    return null;
  }

  String? _validateConfirm(String? value) {
    if (_pinController.text.isEmpty) return null;
    if (value == null || value.isEmpty || value != _pinController.text) {
      return L10n.tr('两次输入的 PIN 码不一致');
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    // 开关关闭:清除全部解锁凭据并禁用应用锁(等同"关闭应用锁")。
    if (!_lockEnabled) {
      setState(() => _saving = true);
      try {
        await _store.clearAppLock();
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(L10n.tr('应用锁已关闭'))));
        Navigator.of(context).pop();
      } catch (_) {
        if (!mounted) return;
        _snack(L10n.tr('保存失败,请重试'));
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }
    int? timeout;
    if (_timing == 'timeout') {
      timeout = int.tryParse(_timeoutController.text);
      if (timeout == null || timeout < 1 || timeout > 60) {
        _snack(L10n.tr('超时时间需为 1-60 分钟'));
        return;
      }
    }
    final patternSet = (_hasPattern && !_clearPattern) || _newPattern != null;
    final pinSet = _hasPin || _pinController.text.isNotEmpty;
    if (!_biometricEnabled && !patternSet && !pinSet) {
      _snack(L10n.tr('请至少设置一种解锁方式(PIN 或图案)'));
      return;
    }
    setState(() => _saving = true);
    try {
      final pin = _pinController.text;
      if (pin.isNotEmpty) {
        final salt = generateSalt();
        await _store.savePinSalt(salt);
        await _store.savePinHash(hashPin(pin, salt));
      }
      if (_newPattern != null) {
        final salt = generateSalt();
        await _store.savePatternSalt(salt);
        await _store.savePatternHash(hashPattern(_newPattern!, salt));
      }
      if (_clearPattern) await _store.clearPattern();
      await _store.setLockEnabled(true);
      // 设备不支持时按"关闭"保存,避免恢复备份后留下不可用配置。
      await _store.setLockBiometric(
        _biometricEnabled && _availableBiometrics.isNotEmpty,
      );
      await _store.setLockTiming(_timing);
      await _store.setLockTimeoutMinutes(timeout ?? 5);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(L10n.tr('应用锁已启用'))));
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      _snack(L10n.tr('保存失败,请重试'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final patternSet = (_hasPattern && !_clearPattern) || _newPattern != null;
    return Scaffold(
      appBar: AppBar(title: Text(L10n.tr('应用锁'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(L10n.tr('启用应用锁')),
                subtitle: Text(
                  _lockEnabled
                      ? L10n.tr('锁定后需解锁方式验证')
                      : L10n.tr('关闭后进入应用不锁定'),
                ),
                value: _lockEnabled,
                onChanged: (value) =>
                    setState(() => _lockEnabled = value),
              ),
              const Divider(),
              if (!_lockEnabled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    L10n.tr('开启后需设置至少一种解锁方式(PIN 或图案)。'),
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (_lockEnabled) ...[
              _sectionTitle(L10n.tr('锁定时机')),
              RadioGroup<String>(
                groupValue: _timing,
                onChanged: (value) => setState(() => _timing = value ?? 'exit'),
                child: Column(
                  children: [
                    RadioListTile<String>(
                      value: 'exit',
                      title: Text(L10n.tr('退出时锁定')),
                      subtitle: Text(L10n.tr('应用进入后台立即锁定')),
                    ),
                    RadioListTile<String>(
                      value: 'timeout',
                      title: Text(L10n.tr('退出且超时锁定')),
                      subtitle: Text(L10n.tr('进入后台超过设定时间后锁定,期间回到前台不锁')),
                    ),
                  ],
                ),
              ),
              if (_timing == 'timeout') ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(L10n.tr('超时时间(分钟)')),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 96,
                      child: TextFormField(
                        controller: _timeoutController,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              const Divider(),
              _sectionTitle(L10n.tr('生物识别解锁')),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(L10n.tr('使用生物识别解锁')),
                subtitle: _availableBiometrics.isEmpty
                    ? Text(L10n.tr('当前设备未检测到生物识别'))
                    : null,
                value: _biometricEnabled,
                onChanged: (value) =>
                    setState(() => _biometricEnabled = value),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  L10n.tr('系统弹窗由设备统一管理,会自动选择可用的人脸或指纹验证方式'),
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _supportText(),
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (_biometricEnabled && _availableBiometrics.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    L10n.tr('当前设备不支持生物识别,保存后将自动关闭'),
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: _hasPin ? L10n.tr('修改 PIN 码(可选)') : L10n.tr('PIN 码'),
                  helperText: L10n.tr('4-6 位数字,用于解锁应用;留空表示不改动'),
                  border: const OutlineInputBorder(),
                ),
                validator: _validatePin,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(
                  labelText: L10n.tr('确认 PIN 码'),
                  border: const OutlineInputBorder(),
                ),
                validator: _validateConfirm,
              ),
              const SizedBox(height: 16),
              if (!patternSet)
                OutlinedButton.icon(
                  onPressed: _saving ? null : _setupPattern,
                  icon: const Icon(Icons.gesture),
                  label: Text(L10n.tr('设置图案解锁')),
                )
              else ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.gesture),
                  title: Text(L10n.tr('图案解锁已设置')),
                  trailing: TextButton(
                    onPressed: _saving ? null : _setupPattern,
                    child: Text(L10n.tr('重新设置')),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() {
                            _newPattern = null;
                            _clearPattern = true;
                          }),
                    child: Text(
                      L10n.tr('清除图案'),
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              ],
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(L10n.tr('保存')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(
      title,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}

/// 图案设置对话框:先绘制一遍,再确认一遍;两次一致返回点序,取消返回 null。
class _PatternSetupDialog extends StatefulWidget {
  const _PatternSetupDialog();

  @override
  State<_PatternSetupDialog> createState() => _PatternSetupDialogState();
}

class _PatternSetupDialogState extends State<_PatternSetupDialog> {
  List<int>? _first;
  String? _hint;

  void _onDraw(List<int> dots) {
    if (dots.length < 4) {
      setState(() => _hint = L10n.tr('至少连接 4 个点,请重试'));
      return;
    }
    if (_first == null) {
      setState(() {
        _first = dots;
        _hint = null;
      });
      return;
    }
    if (listEquals(_first, dots)) {
      Navigator.of(context).pop(dots);
    } else {
      setState(() {
        _first = null;
        _hint = L10n.tr('两次图案不一致,请重新绘制');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        _first == null ? L10n.tr('绘制图案') : L10n.tr('再次绘制确认'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _hint!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ),
          SizedBox(
            width: 280,
            height: 280,
            child: PatternLock(onCompleted: _onDraw),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.tr('取消')),
        ),
      ],
    );
  }
}

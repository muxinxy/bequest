import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../crypto/key_derivation.dart';
import '../storage/secure_store.dart';
import 'home_page.dart';

/// 注册页:收集账号信息与主密码,派生并包装主密钥后提交后端。
/// 用户名/邮箱边输边实时查重;格式问题立即提示(不等点击注册)。
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  late final Future<ApiClient> _api = ApiConfig.client();
  final _store = SecureStore();

  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordConfirmController = TextEditingController();
  final _masterPasswordController = TextEditingController();
  final _masterPasswordConfirmController = TextEditingController();
  final _hintController = TextEditingController();
  final _captchaController = TextEditingController();

  bool _submitting = false;
  String _captchaId = '';
  String _captchaSvg = '';
  bool _captchaFailed = false;

  /// 实时查重结果:null = 未查/检查中;false = 已被占用。
  bool? _usernameAvailable;
  bool? _emailAvailable;
  Timer? _usernameDebounce;
  Timer? _emailDebounce;

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onUsernameChanged);
    _emailController.addListener(_onEmailChanged);
    _refreshCaptcha();
  }

  /// 获取图形验证码(失败显示重试,服务端校验兜底)。
  Future<void> _refreshCaptcha() async {
    try {
      final c = await (await _api).getCaptcha();
      if (mounted) {
        setState(() {
          _captchaId = c['captcha_id']?.toString() ?? '';
          _captchaSvg = c['image_svg']?.toString() ?? '';
          _captchaFailed = _captchaSvg.isEmpty;
          _captchaController.clear();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _captchaId = '';
          _captchaSvg = '';
          _captchaFailed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _usernameDebounce?.cancel();
    _emailDebounce?.cancel();
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _passwordConfirmController.dispose();
    _masterPasswordController.dispose();
    _masterPasswordConfirmController.dispose();
    _hintController.dispose();
    _captchaController.dispose();
    super.dispose();
  }

  void _onUsernameChanged() {
    _usernameDebounce?.cancel();
    final value = _usernameController.text.trim();
    // 格式先本地校验;合法才查重(减少请求)。
    if (!_validUsername(value)) {
      setState(() => _usernameAvailable = null);
      return;
    }
    _usernameDebounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final res = await (await _api).checkUsername(value);
        if (mounted) {
          setState(() => _usernameAvailable = res['available'] == true);
        }
      } catch (_) {
        // 查重失败(网络):不阻塞,提交时由服务端兜底。
      }
    });
  }

  void _onEmailChanged() {
    _emailDebounce?.cancel();
    final value = _emailController.text.trim();
    if (!_validEmail(value)) {
      setState(() => _emailAvailable = null);
      return;
    }
    _emailDebounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final res = await (await _api).checkEmail(value);
        if (mounted) {
          setState(() => _emailAvailable = res['available'] == true);
        }
      } catch (_) {
        // 同上。
      }
    });
  }

  static bool _validUsername(String value) =>
      value.length >= 3 && value.length <= 20 && RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(value);

  static bool _validEmail(String value) =>
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    // 主密码不能与登录密码相同。
    if (_masterPasswordController.text == _passwordController.text) {
      _showError('主密码不能与登录密码相同');
      return;
    }
    setState(() => _submitting = true);
    try {
      final salt = generateSalt();
      final masterKey = await deriveMasterKey(
        _masterPasswordController.text,
        salt,
      );
      final wrappingKey = generateWrappingKey();
      final wrapped = wrapMasterKey(masterKey, wrappingKey);

      final response = await (await _api).register(
        username: _usernameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
        masterKeyWrapped: wrapped,
        masterSalt: salt,
        captchaId: _captchaId,
        // 后端大小写不敏感:统一转大写提交。
        captcha: _captchaController.text.trim().toUpperCase(),
      );

      await _store.saveJwt(_extractJwt(response));
      await _store.saveMasterKey(masterKey);
      await _store.saveMasterSalt(salt);
      await _store.saveWrappingKey(wrappingKey);
      final hint = _hintController.text.trim();
      if (hint.isNotEmpty) await _store.saveMasterHint(hint);
      await _store.saveStorageMode('cloud');

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const HomePage()),
      );
    } on ApiException catch (e) {
      if (e.message.contains('验证码')) await _refreshCaptcha();
      _showError(e.message);
    } catch (_) {
      _showError('注册失败,请检查网络后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _extractJwt(Map<String, dynamic> response) {
    for (final key in const ['token', 'access_token', 'jwt']) {
      final value = response[key];
      if (value is String && value.isNotEmpty) return value;
    }
    throw ApiException('服务器未返回登录凭证');
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('注册')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          // 失焦/交互后即显示校验错误(红字),提交时仍会再次校验。
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: '用户名',
                  helperText: '3-20 位,字母/数字/下划线',
                  border: const OutlineInputBorder(),
                  suffixIcon: _usernameAvailable == null
                      ? null
                      : Icon(
                          _usernameAvailable == true
                              ? Icons.check_circle
                              : Icons.error,
                          color: _usernameAvailable == true
                              ? Colors.green
                              : Colors.red,
                        ),
                ),
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.isEmpty) return '请输入用户名';
                  if (!_validUsername(v)) {
                    return '用户名需 3-20 位字母/数字/下划线';
                  }
                  if (_usernameAvailable == false) return '用户名已被占用';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: '邮箱',
                  border: const OutlineInputBorder(),
                  suffixIcon: _emailAvailable == null
                      ? null
                      : Icon(
                          _emailAvailable == true
                              ? Icons.check_circle
                              : Icons.error,
                          color: _emailAvailable == true
                              ? Colors.green
                              : Colors.red,
                        ),
                ),
                validator: (value) {
                  final v = value?.trim() ?? '';
                  if (v.isEmpty) return '请输入邮箱';
                  if (!_validEmail(v)) return '邮箱格式不正确';
                  if (_emailAvailable == false) return '邮箱已被注册';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '登录密码',
                  helperText: '至少 8 位;用于登录账号',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.length < 8)
                    ? '密码至少 8 位'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordConfirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '确认登录密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value != _passwordController.text
                    ? '两次输入的密码不一致'
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _masterPasswordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '主密码',
                  helperText: '用于加密资产数据,务必牢记;不能与登录密码相同',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.length < 8) return '主密码至少 8 位';
                  if (value == _passwordController.text) return '主密码不能与登录密码相同';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _masterPasswordConfirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '确认主密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value != _masterPasswordController.text ? '两次输入的主密码不一致' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _hintController,
                decoration: const InputDecoration(
                  labelText: '主密码提示语(可选)',
                  helperText: '忘记主密码时帮助回忆,不暴露密码本身',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _captchaController,
                      decoration: const InputDecoration(
                        labelText: '验证码',
                        hintText: '输入图形验证码',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          (value == null || value.trim().isEmpty)
                              ? '请输入验证码'
                              : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 点击图片刷新验证码。
                  InkWell(
                    onTap: _refreshCaptcha,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: 110,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: _captchaSvg.isEmpty
                          ? Text(
                              _captchaFailed ? '加载失败,点此重试' : '加载中',
                              style: const TextStyle(fontSize: 13),
                            )
                          : SvgPicture.string(
                              _captchaSvg,
                              width: 100,
                              height: 40,
                              placeholderBuilder: (_) => const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('注册'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

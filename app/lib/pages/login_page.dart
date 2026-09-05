import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../api/api_client.dart';
import '../api/api_config.dart';
import '../crypto/recover_keys.dart';
import '../l10n/app_l10n.dart';
import '../storage/secure_store.dart';
import 'forgot_password_page.dart';
import 'home_page.dart';
import 'local_unlock_page.dart';
import 'register_page.dart';
import 'reset_master_password_page.dart';
import 'server_settings_page.dart';

/// 登录页:提交用户名与密码,成功后进入主页。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();

  /// 每次访问按当前配置构造客户端:从服务器设置页返回后地址变更立即生效
  /// (不能用 late final 缓存,否则改地址后验证码仍请求旧地址)。
  Future<ApiClient> get _api => ApiConfig.client();
  final _store = SecureStore();

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _captchaController = TextEditingController();

  bool _submitting = false;
  String _captchaId = '';
  String _captchaSvg = '';
  bool _captchaFailed = false;

  @override
  void initState() {
    super.initState();
    _refreshCaptcha();
    _restoreSession();
  }

  /// 冷启动/Web 刷新时恢复已登录会话:
  /// - 云端:本地存有 JWT → 直接进主页(token 有效性由主页 GET /me 校验,失效回登录页);
  /// - 本地模式:有当前本地账户 → 进账户选择页(须验证该账户主密码才能进入),
  ///   否则留在登录页走「进入本地模式」。
  Future<void> _restoreSession() async {
    try {
      final store = SecureStore();
      final jwt = await store.readJwt();
      final mk = await store.readMasterKey();
      final mode = await store.readStorageMode();
      if (mode == 'local') {
        final active = await store.readActiveLocalProfileId();
        if (active == null || active.isEmpty || mk == null || mk.isEmpty) {
          return;
        }
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const LocalUnlockPage()),
        );
        return;
      }
      if (jwt == null || jwt.isEmpty) return;
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const HomePage()),
      );
    } catch (_) {
      // 存储读取失败:留在登录页。
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _captchaController.dispose();
    super.dispose();
  }

  /// 获取图形验证码(注册/登录共用;失败显示重试,服务端校验兜底)。
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
      // 验证码获取失败:展示重试入口,不无限转圈。
      if (mounted) {
        setState(() {
          _captchaId = '';
          _captchaSvg = '';
          _captchaFailed = true;
        });
      }
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      // 预检服务器可用性:不可达立即反馈,不等登录请求超时转圈。
      final api = await _api;
      if (!await _checkServer(api)) {
        if (!mounted) return;
        _showError(L10n.tr('无法连接服务器,请检查网络或服务器地址'));
        return;
      }
      final response = await api.login(
        username: _usernameController.text.trim(),
        password: _passwordController.text,
        captchaId: _captchaId,
        // 后端大小写不敏感:统一转大写提交。
        captcha: _captchaController.text.trim().toUpperCase(),
      );
      final token = _extractJwt(response);
      await _store.saveJwt(token);
      // 登录即云端模式:避免沿用上次的本地模式设置。
      await _store.saveStorageMode('cloud');

      // 跨设备恢复所需的服务端盐。
      final serverSalt = response['master_salt']?.toString() ?? '';
      // 老账号回填:注册前无盐上传,本机有盐而服务端缺 → 上传,之后新设备可恢复。
      final localSalt = await _store.readMasterSalt();
      if (serverSalt.isEmpty && localSalt != null && localSalt.isNotEmpty) {
        try {
          await api.updateMasterSalt(token, localSalt);
        } catch (_) {
          // 回填失败不影响登录。
        }
      }

      // 恢复加密密钥:仅当本机确无主密钥(真·新设备),或本机盐与服务端
      // 不一致(主密码已在其他设备修改/重置)时弹窗;同设备重复登录
      // 主密钥已保留(clearAll 不清加密凭据),不再弹。
      final localMk = await _store.readMasterKey();
      final mkMissing = localMk == null || localMk.isEmpty;
      final saltMismatch = localSalt != null &&
          localSalt.isNotEmpty &&
          serverSalt.isNotEmpty &&
          localSalt != serverSalt;
      if ((mkMissing || saltMismatch) && serverSalt.isNotEmpty) {
        final choice = await _recoverKeys(token, serverSalt);
        if (choice == _RecoveryChoice.reset) {
          // 忘记主密码:重置只需账户密码,不需要旧主密码。
          if (!mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const ResetMasterPasswordPage(),
            ),
          );
          if (!mounted) return;
          final mk = await _store.readMasterKey();
          if (!mounted) return;
          if (mk != null && mk.isNotEmpty) {
            // 重置成功:本地已有新密钥,直接进主页。
            Navigator.of(context).pushReplacement(
              MaterialPageRoute<void>(builder: (_) => const HomePage()),
            );
          } else {
            // 用户未完成重置:清凭据留在登录页。
            await _store.clearAll();
            if (mounted) _showError(L10n.tr('未恢复加密密钥,请重新登录重试'));
          }
          return;
        }
        if (choice != _RecoveryChoice.recovered) {
          if (!mounted) return;
          _showError(L10n.tr('未恢复加密密钥,请重新登录重试'));
          await _store.clearAll();
          return;
        }
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const HomePage()),
      );
    } on ApiException catch (e) {
      // 验证码错误/过期:刷新验证码让用户重试。
      if (e.message.contains('验证码')) await _refreshCaptcha();
      _showError(e.message);
    } catch (_) {
      _showError(L10n.tr('登录失败,请检查网络后重试'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 快速服务器可用性检查:GET /healthz,2 秒超时。
  Future<bool> _checkServer(ApiClient api) async {
    try {
      await api
          .checkServerHealth()
          .timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  String _extractJwt(Map<String, dynamic> response) {
    for (final key in const ['token', 'access_token', 'jwt']) {
      final value = response[key];
      if (value is String && value.isNotEmpty) return value;
    }
    throw ApiException('服务器未返回登录凭证');
  }

  /// 跨设备恢复结果。
  /// [recovered] = 主密码+盐重新派生成功;[reset] = 用户选择重置主密码;
  /// [cancelled] = 取消/失败。
  Future<_RecoveryChoice> _recoverKeys(String jwt, String salt) async {
    final api = await _api;
    if (!mounted) return _RecoveryChoice.cancelled;
    final creds = await showDialog<({String? master, String? account, bool reset})>(
      context: context,
      // 键盘弹出时 DialogRoute 内置 viewInsets 处理会自动上移;
      // 不要再手动加 viewInsets padding,否则键盘高度被双重计算,
      // 对话框整体被顶出屏幕。
      builder: (context) => const _RecoveryDialog(),
    );
    if (creds == null || !mounted) return _RecoveryChoice.cancelled;
    if (creds.reset) return _RecoveryChoice.reset;
    final r = await recoverMasterKeys(
      store: _store,
      api: api,
      jwt: jwt,
      masterSalt: salt,
      masterPassword: creds.master ?? '',
      accountPassword: creds.account ?? '',
    );
    if (!r.ok && mounted) _showError(r.error!);
    return r.ok ? _RecoveryChoice.recovered : _RecoveryChoice.cancelled;
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 64),
              const Icon(Icons.shield_outlined, size: 72),
              const SizedBox(height: 8),
              Text(
                L10n.tr('托孤'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 4),
              Text(
                L10n.tr('数字资产安全传承'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 40),
              TextFormField(
                controller: _usernameController,
                decoration: InputDecoration(
                  labelText: L10n.tr('用户名/邮箱'),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? L10n.tr('请输入用户名或邮箱')
                    : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: L10n.tr('密码'),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.isEmpty)
                    ? L10n.tr('请输入密码')
                    : null,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _captchaController,
                      decoration: InputDecoration(
                        labelText: L10n.tr('验证码'),
                        hintText: L10n.tr('输入图形验证码'),
                        border: const OutlineInputBorder(),
                      ),
                      validator: (value) =>
                          (value == null || value.trim().isEmpty)
                              ? L10n.tr('请输入验证码')
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
                              _captchaFailed
                                  ? L10n.tr('加载失败,点此重试')
                                  : L10n.tr('加载中'),
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
                onPressed: _submitting ? null : _login,
                child: _submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(L10n.tr('登录')),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const RegisterPage(),
                          ),
                        );
                      },
                child: Text(L10n.tr('还没有账号?去注册')),
              ),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ForgotPasswordPage(),
                          ),
                        );
                      },
                child: Text(
                  L10n.tr('忘记密码'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _submitting
                    ? null
                    : () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const LocalUnlockPage(),
                          ),
                        );
                      },
                child: Text(L10n.tr('进入本地模式')),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _submitting
                    ? null
                    : () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ServerSettingsPage(),
                          ),
                        );
                        // 返回后地址可能已变更:刷新验证码走新地址。
                        await _refreshCaptcha();
                      },
                child: Text(
                  L10n.tr('服务器设置'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 跨设备恢复结果。
enum _RecoveryChoice { recovered, cancelled, reset }

/// 跨设备恢复对话框:主密码(重派生主密钥)+ 账户密码(更新继承交接密钥);
/// 提供「忘记主密码?去重置」出口(重置只需账户密码)。
/// controller 随 State 释放,避免对话框退场动画期间访问已释放的 controller。
class _RecoveryDialog extends StatefulWidget {
  const _RecoveryDialog();

  @override
  State<_RecoveryDialog> createState() => _RecoveryDialogState();
}

class _RecoveryDialogState extends State<_RecoveryDialog> {
  final _masterController = TextEditingController();
  final _accountController = TextEditingController();

  @override
  void dispose() {
    _masterController.dispose();
    _accountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(L10n.tr('恢复加密密钥')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Text(
            L10n.tr('此设备首次登录,请输入主密码恢复本机加密密钥(资产凭据不受影响)。'),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _masterController,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(
              labelText: L10n.tr('主密码'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _accountController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: L10n.tr('账户密码(用于更新继承交接密钥)'),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop((master: '', account: '', reset: true)),
          child: Text(
                  L10n.tr('忘记主密码?去重置'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(L10n.tr('取消')),
        ),
        FilledButton(
          onPressed: () {
            // 校验失败不关闭弹框:主密码为空直接提示并留在对话框内。
            if (_masterController.text.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(L10n.tr('请输入主密码'))),
              );
              return;
            }
            Navigator.of(context).pop((
              master: _masterController.text,
              account: _accountController.text,
              reset: false,
            ));
          },
          child: Text(L10n.tr('恢复')),
        ),
      ],
    );
  }
}

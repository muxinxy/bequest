import 'package:flutter/material.dart';

import '../storage/secure_store.dart';
import 'attempt_guard.dart';
import 'key_derivation.dart';

/// 用输入的主密码重新派生密钥,与本地保存的主密钥比对。
///
/// 旧账号未保存盐(注册时的缺口)或未登录时返回 false。
/// ponytail: 常数时间比较在此场景收益有限(本地凭据,无远程侧信道),直接用 ==。
Future<bool> verifyMasterPassword(
  String inputPassword, {
  SecureStore? store,
}) async {
  final s = store ?? SecureStore();
  final salt = await s.readMasterSalt();
  if (salt == null || salt.isEmpty) return false;
  final masterKey = await s.readMasterKey();
  if (masterKey == null) return false;
  return masterKey == await deriveMasterKey(inputPassword, salt);
}

/// 主密码解锁纯逻辑(无 UI 依赖,可单测):
/// 限流锁定中 → false 且不计数;校验通过 → 清零计数并返回 true;
/// 校验失败 → 累计一次失败并返回 false。
/// 锁屏/导出/导入/修改主密码共用,避免各处实现漂移。
Future<bool> masterPasswordUnlock({
  required SecureStore store,
  required AttemptGuard guard,
  required String password,
}) async {
  if (await guard.checkLocked()) return false;
  if (await verifyMasterPassword(password, store: store)) {
    await guard.recordSuccess();
    return true;
  }
  await guard.recordFailure();
  return false;
}

/// 校验主密码并应用失败限流:锁定期间拒绝;失败累计,达到阈值锁定 60 秒;
/// 成功清零。消息(锁定倒计时/主密码错误)由本函数统一提示,返回是否通过。
Future<bool> guardedVerifyMasterPassword(
  BuildContext context,
  AttemptGuard guard,
  String password,
) async {
  final messenger = ScaffoldMessenger.of(context);
  if (await masterPasswordUnlock(
    store: SecureStore(),
    guard: guard,
    password: password,
  )) {
    return true;
  }
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        await guard.checkLocked()
            ? '尝试次数过多,请等待 ${await guard.remainingSeconds()} 秒后重试'
            : '主密码错误',
      ),
    ),
  );
  return false;
}

/// 弹出主密码输入对话框,返回输入内容;取消返回 null。
/// 已设置提示语时在对话框中展示(帮助回忆,不暴露密码本身)。
Future<String?> showMasterPasswordDialog(BuildContext context) async {
  String? hint;
  try {
    final store = SecureStore();
    hint = await store.readMasterHint();
    // 标准槽为空但处于本地模式:回退读当前激活账户的提示语。
    // (旧版本创建的本地账户 hint 只存账户槽,锁屏不会触发 activateLocalProfile
    // 同步标准槽,直接读会漏。)
    if (hint == null || hint.isEmpty) {
      final activeId = await store.readActiveLocalProfileId();
      if (activeId != null && activeId.isNotEmpty) {
        final profile = await store.readLocalProfile(activeId);
        hint = profile.hint;
      }
    }
  } catch (_) {
    // 插件缺失(测试环境)时忽略提示语。
  }
  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    builder: (context) => _MasterPasswordDialog(hint: hint),
  );
}

/// 主密码输入对话框。controller 在 State.dispose 中释放:
/// showDialog 返回时退出动画仍在进行,过早 dispose 会导致
/// TextField 在重建时访问已释放的 controller 而崩溃。
class _MasterPasswordDialog extends StatefulWidget {
  const _MasterPasswordDialog({this.hint});

  final String? hint;

  @override
  State<_MasterPasswordDialog> createState() => _MasterPasswordDialogState();
}

class _MasterPasswordDialogState extends State<_MasterPasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = widget.hint;
    return AlertDialog(
      title: const Text('请输入主密码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '主密码',
              border: OutlineInputBorder(),
            ),
          ),
          if (hint != null && hint.isNotEmpty) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '主密码提示: $hint',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('确认'),
        ),
      ],
    );
  }
}

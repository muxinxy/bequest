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
  return masterKey == deriveMasterKey(inputPassword, salt);
}

/// 校验主密码并应用失败限流:锁定期间拒绝;失败累计,达到阈值锁定 60 秒;
/// 成功清零。消息(锁定倒计时/主密码错误)由本函数统一提示,返回是否通过。
Future<bool> guardedVerifyMasterPassword(
  BuildContext context,
  AttemptGuard guard,
  String password,
) async {
  final messenger = ScaffoldMessenger.of(context);
  if (await guard.checkLocked()) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('尝试次数过多,请等待 ${await guard.remainingSeconds()} 秒后重试'),
      ),
    );
    return false;
  }
  if (await verifyMasterPassword(password)) {
    await guard.recordSuccess();
    return true;
  }
  await guard.recordFailure();
  final locked = await guard.checkLocked();
  messenger.showSnackBar(
    SnackBar(
      content: Text(
        locked
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
  final controller = TextEditingController();
  String? hint;
  try {
    hint = await SecureStore().readMasterHint();
  } catch (_) {
    // 插件缺失(测试环境)时忽略提示语。
  }
  if (!context.mounted) return null;
  final password = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('请输入主密码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: controller,
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
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('确认'),
        ),
      ],
    ),
  );
  controller.dispose();
  return password;
}

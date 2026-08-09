import 'package:flutter/material.dart';

import '../storage/secure_store.dart';
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

/// 弹出主密码输入对话框,返回输入内容;取消返回 null。
Future<String?> showMasterPasswordDialog(BuildContext context) async {
  final controller = TextEditingController();
  final password = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('请输入主密码'),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: '主密码',
          border: OutlineInputBorder(),
        ),
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

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 计算 PIN 的校验哈希:sha256(salt + pin)。
String hashPin(String pin, String salt) {
  return sha256.convert(utf8.encode('$salt$pin')).toString();
}

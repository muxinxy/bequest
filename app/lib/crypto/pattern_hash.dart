import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 计算图案解锁序列的校验哈希:sha256(salt + 'pattern:' + dots.join(','))。
/// [dots] 为行优先点序,如 [0, 1, 2, 5, 8]。
String hashPattern(List<int> dots, String salt) {
  return sha256
      .convert(utf8.encode('$salt${'pattern:${dots.join(',')}'}'))
      .toString();
}

/// 校验输入的图案序列是否与已存哈希一致。
bool verifyPattern(List<int> dots, String salt, String hash) {
  return hashPattern(dots, salt) == hash;
}

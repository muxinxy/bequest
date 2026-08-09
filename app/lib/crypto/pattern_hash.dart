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

/// 判定一次图案尝试是否应记为失败(用于应用锁限流):
/// 点数不足 4、盐/哈希缺失(损坏状态)或校验失败 → true(记失败)。
/// 点数充足且校验通过 → false(记成功)。
///
/// 与 PIN 路径对齐:任何无法通过校验的尝试都计失败,包括短图案
/// (设置时合法图案至少 4 点,<4 点必为错误尝试)与存储损坏的空盐/哈希。
bool shouldRecordPatternFailure({
  required String? salt,
  required String? hash,
  required List<int> dots,
}) {
  if (dots.length < 4) return true;
  if (salt == null || salt.isEmpty || hash == null || hash.isEmpty) return true;
  return !verifyPattern(dots, salt, hash);
}

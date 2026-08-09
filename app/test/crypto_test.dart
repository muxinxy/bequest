import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/crypto/asset_crypto.dart';
import 'package:bequest/crypto/pin_hash.dart';

void main() {
  final key = base64.encode(List<int>.filled(32, 7));
  final wrongKey = base64.encode(List<int>.filled(32, 8));

  group('encryptSensitiveData/decryptSensitiveData', () {
    test('往返一致(含中文)', () {
      const plain = '{"credentials":"账号/密码123","notes":"备注备注"}';
      final blob = encryptSensitiveData(plain, key);
      expect(blob, isNotEmpty);
      expect(decryptSensitiveData(blob, key), plain);
    });

    test('错误密钥解密失败', () {
      final blob = encryptSensitiveData('{"a":1}', key);
      expect(() => decryptSensitiveData(blob, wrongKey), throwsException);
    });

    test('篡改密文解密失败', () {
      final blob = base64.decode(encryptSensitiveData('{"a":1}', key));
      blob[blob.length - 1] ^= 0xFF; // 翻转 tag 最后一位
      expect(() => decryptSensitiveData(base64.encode(blob), key),
          throwsException);
    });

    test('过短密文抛格式错误', () {
      expect(
        () => decryptSensitiveData(base64.encode(List<int>.filled(8, 0)), key),
        throwsFormatException,
      );
    });
  });

  test('hashPin 稳定且随盐变化', () {
    expect(hashPin('1234', 'saltA'), hashPin('1234', 'saltA'));
    expect(hashPin('1234', 'saltA'), isNot(hashPin('1234', 'saltB')));
    expect(hashPin('1234', 'saltA'), isNot(hashPin('5678', 'saltA')));
  });
}

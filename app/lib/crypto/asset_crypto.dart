import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

const int _nonceLength = 12;
const int _macLength = 16;

/// 用主密钥 AES-256-GCM 加密敏感数据,输出 base64(nonce || ciphertext || tag)。
///
/// 与 wrapMasterKey 不同:此处保留完整 MAC tag,数据必须可解密。
/// 返回 base64 字符串。
String encryptSensitiveData(String plainJson, String masterKeyB64) {
  final nonce = _randomBytes(_nonceLength);
  final cipher = _gcm(true, masterKeyB64, nonce);
  final plain = utf8.encode(plainJson);
  final out = Uint8List(cipher.getOutputSize(plain.length));
  final len = cipher.processBytes(plain, 0, plain.length, out, 0);
  cipher.doFinal(out, len);
  // out = [ciphertext(plain.length) || tag(macLength)],doFinal 返回值不可靠,按长度切片。
  final blob = Uint8List.sublistView(out, 0, plain.length + _macLength);
  return base64.encode([...nonce, ...blob]);
}

/// 解密 [encryptSensitiveData] 的输出。密钥错误或数据被篡改时抛异常。
String decryptSensitiveData(String blobB64, String masterKeyB64) {
  final blob = base64.decode(blobB64);
  if (blob.length < _nonceLength + _macLength) {
    throw const FormatException('密文数据格式错误');
  }
  final nonce = Uint8List.sublistView(blob, 0, _nonceLength);
  final ciphertext = Uint8List.sublistView(blob, _nonceLength);
  final cipher = _gcm(false, masterKeyB64, nonce);
  final out = Uint8List(cipher.getOutputSize(ciphertext.length));
  final len = cipher.processBytes(ciphertext, 0, ciphertext.length, out, 0);
  // tag 校验失败(密钥错误/篡改)时 doFinal 抛 InvalidCipherTextException。
  cipher.doFinal(out, len);
  // GCM 明文长度 = 密文长度 - tag 长度。
  final plain = Uint8List.sublistView(out, 0, ciphertext.length - _macLength);
  return utf8.decode(plain);
}

GCMBlockCipher _gcm(bool forEncryption, String masterKeyB64, Uint8List nonce) {
  return GCMBlockCipher(AESEngine())
    ..init(
      forEncryption,
      AEADParameters(
        KeyParameter(base64.decode(masterKeyB64)),
        _macLength * 8,
        nonce,
        Uint8List(0),
      ),
    );
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import '../l10n/app_l10n.dart';

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
    throw FormatException(L10n.tr('密文数据格式错误'));
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

// ---------- 资产级密钥隔离(ADR-1 扩展) ----------

/// 生成 32 字节随机资产密钥(AK),返回 base64。
///
/// 每资产独立 AK:内容用 AK 加密,AK 再分别被主密钥(MK)与继承包装密钥(WK)
/// 包装上传——号主持 MK 解出 AK,指定继承人持 WK 只解出该资产的 AK。
String generateAssetKey() => base64.encode(_randomBytes(32));

/// 用 [wrappingKeyB64](MK 或 WK)包装资产密钥,输出可解密的 base64(nonce||ct||tag)。
///
/// 复用 [encryptSensitiveData] 的 AES-256-GCM(带 tag);解开用 [decryptSensitiveData]。
String wrapAssetKey(String assetKeyB64, String wrappingKeyB64) =>
    encryptSensitiveData(assetKeyB64, wrappingKeyB64);

/// 解开 [wrapAssetKey] 的产物,返回资产密钥 base64。密钥错误抛异常。
String unwrapAssetKey(String wrappedB64, String wrappingKeyB64) =>
    decryptSensitiveData(wrappedB64, wrappingKeyB64);

/// 解密资产内容:有 [assetKeyWrappedMk](资产级隔离)时解出 AK 再解密;
/// 老资产(无包装)回退直接用主密钥解密。
///
/// [encryptedData] 为资产密文 base64;[assetKeyWrappedMk] 为可选的主密钥包装。
String decryptAssetData(String encryptedData, String masterKeyB64,
    {String? assetKeyWrappedMk}) {
  final key = (assetKeyWrappedMk == null || assetKeyWrappedMk.isEmpty)
      ? masterKeyB64
      : unwrapAssetKey(assetKeyWrappedMk, masterKeyB64);
  return decryptSensitiveData(encryptedData, key);
}

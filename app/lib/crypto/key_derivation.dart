import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'key_derivation_io.dart'
    if (dart.library.js_interop) 'key_derivation_web.dart';

/// 生成 16 字节随机盐,返回 base64 字符串。
String generateSalt() {
  return base64.encode(_randomBytes(16));
}

/// 用 Argon2id 从主密码派生 32 字节主密钥,返回 base64 字符串。
///
/// [saltB64] 为 base64 编码的盐。
/// ponytail: VM/桌面走 pointycastle native int;web 走 hash-wasm WASM
/// (自托管 web/assets/hash-wasm.js,~200ms;Register64 纯 JS 需 ~33s)。
/// 两者参数一致(memory 65536 KiB, iterations 3, parallelism 4, V13),
/// 派生结果与旧 argon2 1.0.1 逐字节相同,见 test/web_argon2_compat_test.dart。
Future<String> deriveMasterKey(String masterPassword, String saltB64) =>
    platformDeriveMasterKey(masterPassword, saltB64);

/// 生成 32 字节随机包装密钥,返回 base64 字符串。
String generateWrappingKey() {
  return base64.encode(_randomBytes(32));
}

/// 用 AES-256-GCM 包装主密钥,输出 base64(nonce || ciphertext)。
///
/// ponytail: package:crypto 无 AES,改用 pointycastle(AESEngine + GCM)。
/// GCM 输出末尾的 16 字节 MAC tag 按约定丢弃;若后续需要解包,
/// 契约需改为包含 tag(base64(nonce || ciphertext || tag))。
String wrapMasterKey(String masterKeyB64, String wrappingKeyB64) {
  final nonce = _randomBytes(12);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(base64.decode(wrappingKeyB64)),
        128,
        nonce,
        Uint8List(0),
      ),
    );
  final plain = base64.decode(masterKeyB64);
  final out = Uint8List(cipher.getOutputSize(plain.length));
  final len = cipher.processBytes(plain, 0, plain.length, out, 0);
  cipher.doFinal(out, len);
  final cipherText = Uint8List.sublistView(out, 0, plain.length);
  return base64.encode([...nonce, ...cipherText]);
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

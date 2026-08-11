import 'dart:convert';
import 'dart:js_util' as js_util;

/// Web 实现:hash-wasm WASM(自托管 UMD 于 web/assets/hash-wasm.js)。
/// 实测 ~200ms,替代 pointycastle Register64 纯 JS(~33s)。
///
/// hash-wasm argon2id 参数:argon2id V13,iterations 3,memorySize 65536,
/// parallelism 4,hashLength 32——与 pointycastle/argon2 1.0.1 完全一致,
/// 派生结果逐字节相同(见 test/web_argon2_compat_test.dart 锚值)。
Future<String> platformDeriveMasterKey(
  String masterPassword,
  String saltB64,
) async {
  final hashwasm = js_util.getProperty(js_util.globalThis, 'hashwasm');
  final argon2id = js_util.getProperty(hashwasm, 'argon2id');
  final result = await js_util.promiseToFuture(
    js_util.callMethod(argon2id, 'call', [
      js_util.jsify({
        'password': utf8.encode(masterPassword),
        'salt': base64.decode(saltB64),
        'iterations': 3,
        'memorySize': 65536,
        'parallelism': 4,
        'hashLength': 32,
        'outputType': 'binary',
      }),
    ]),
  );
  // hashBinary 为 JS Uint8Array → dartify 为 List<int>。
  final bytes = js_util.dartify(js_util.getProperty(result, 'hashBinary'))
      as List<dynamic>;
  return base64.encode(bytes.cast<int>());
}

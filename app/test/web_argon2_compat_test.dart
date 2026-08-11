import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/crypto/key_derivation.dart';

/// 派生结果回归锚:VM(native int)/web(hash-wasm WASM)两平台必须
/// 与旧 argon2 1.0.1 逐字节一致,否则移动端已存用户无法解锁。
void main() {
  const password = 'P@ssw0rd-测试-123';
  final saltB64 = 'aGFzaC1zYWx0LTE2LWJ5dGVzIQ=='; // 固定 16 字节

  test('deriveMasterKey 与 argon2 1.0.1 逐字节一致(回归锚)', () async {
    // 锚值由旧 argon2 1.0.1 在相同参数下派生,交叉验证 pointycastle
    // Register64/native int 与 hash-wasm 后固定。
    expect(await deriveMasterKey(password, saltB64),
        '9aHZQKgo15d3YYwzZJoD1Xy85voMElJo7SM+XB2xKWE=');
  });
}

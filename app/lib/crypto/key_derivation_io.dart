import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/key_derivators/argon2.dart'
    show Argon2BytesGenerator;
import 'package:pointycastle/key_derivators/api.dart' show Argon2Parameters;

/// VM/桌面实现:pointycastle native int,~1.5s。
Future<String> platformDeriveMasterKey(
  String masterPassword,
  String saltB64,
) async {
  final params = Argon2Parameters(
    Argon2Parameters.ARGON2_id,
    base64.decode(saltB64),
    iterations: 3,
    memory: 65536,
    lanes: 4,
    desiredKeyLength: 32,
  );
  final gen = Argon2BytesGenerator()..init(params);
  final out = Uint8List(32);
  gen.deriveKey(utf8.encode(masterPassword), 0, out, 0);
  return base64.encode(out);
}

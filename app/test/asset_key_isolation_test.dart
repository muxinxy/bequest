import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/crypto/asset_crypto.dart';
import 'package:bequest/crypto/key_derivation.dart';

/// 资产级密钥隔离:AK 加密内容,AK 分别被 MK/WK 包装;号主与继承人都能解开。
void main() {
  const payload = '{"credentials":"secret","notes":"note"}';

  // 用真实派生产生 32 字节密钥(确保密钥长度合法)。
  late String mk;
  late String wk;

  setUpAll(() async {
    mk = await deriveMasterKey('master-pass', 'c2FsdHNhbHRzYWx0c2FsdA==');
    wk = await deriveMasterKey('wrap-pass', 'd3JhcHNhbHR3cmFwc2FsdA==');
  });

  test('AK 包装往返:号主(MK)与继承人(WK)都能解开', () {
    final ak = generateAssetKey();
    // 内容用 AK 加密。
    final encrypted = encryptSensitiveData(payload, ak);
    // AK 双包装。
    final wrappedMk = wrapAssetKey(ak, mk);
    final wrappedWk = wrapAssetKey(ak, wk);

    // 号主:解出 AK → 解密内容。
    final ownerAk = unwrapAssetKey(wrappedMk, mk);
    expect(ownerAk, ak);
    expect(decryptSensitiveData(encrypted, ownerAk), payload);

    // 继承人:解出同一 AK → 解密内容。
    final inheritorAk = unwrapAssetKey(wrappedWk, wk);
    expect(inheritorAk, ak);
    expect(decryptSensitiveData(encrypted, inheritorAk), payload);

    // 错误的包装密钥无法解开。
    expect(() => unwrapAssetKey(wrappedMk, wk), throwsException);
  });

  test('decryptAssetData:有包装走 AK,无包装回退主密钥(老资产)', () {
    final ak = generateAssetKey();
    final encrypted = encryptSensitiveData(payload, ak);
    final wrappedMk = wrapAssetKey(ak, mk);
    expect(decryptAssetData(encrypted, mk, assetKeyWrappedMk: wrappedMk), payload);

    // 老资产:无 asset_key_wrapped_mk → 直接用 MK 解密(旧格式数据兼容)。
    final legacy = encryptSensitiveData(payload, mk);
    expect(decryptAssetData(legacy, mk), payload);
  });

  test('每次生成独立 AK(资产间隔离)', () {
    expect(generateAssetKey(), isNot(generateAssetKey()));
    final a = encryptSensitiveData(payload, generateAssetKey());
    final b = encryptSensitiveData(payload, generateAssetKey());
    expect(a, isNot(b));
  });

  test('导出文件加密往返(encryptSensitiveData 直接复用)', () {
    final exported = encryptSensitiveData(payload, mk);
    expect(decryptSensitiveData(exported, mk), payload);
    expect(jsonDecode(decryptSensitiveData(exported, mk)), {
      'credentials': 'secret',
      'notes': 'note',
    });
  });
}

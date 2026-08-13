import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/crypto/key_derivation.dart';
import 'package:bequest/crypto/pin_hash.dart';
import 'package:bequest/main.dart';
import 'package:bequest/storage/secure_store.dart';

/// 回归:锁屏"用主密码解锁"真实可点。
/// 锁屏位于 MaterialApp.builder 内(与主 Navigator 是兄弟节点而非后代),
/// 曾导致 showDialog 抛 "no Navigator" 异常,点击后毫无反应。
void main() {
  const salt = 'c2FsdA=='; // base64("salt")
  const correct = 'correct';
  const pin = '123456';

  Future<void> seedLockedApp() async {
    FlutterSecureStoragePlatform.instance = TestFlutterSecureStoragePlatform({});
    final store = SecureStore();
    await store.saveMasterSalt(salt);
    await store.saveMasterKey(await deriveMasterKey(correct, salt));
    await store.savePinSalt(salt);
    await store.savePinHash(hashPin(pin, salt));
    await store.setLockEnabled(true);
  }

  Future<void> openMasterDialog(WidgetTester tester) async {
    await tester.pumpWidget(const BequestApp());
    await tester.pumpAndSettle();
    // 已配置 PIN:锁屏出现且不会自动解锁。
    expect(find.text('应用已锁定'), findsOneWidget);
    await tester.ensureVisible(find.text('用主密码解锁'));
    await tester.tap(find.text('用主密码解锁'));
    await tester.pumpAndSettle();
  }

  testWidgets('用主密码解锁:对话框正常弹出,正确密码解锁成功', (tester) async {
    await seedLockedApp();
    await openMasterDialog(tester);

    // 回归点:对话框必须能弹出(修复前这里直接抛异常)。
    expect(find.text('请输入主密码'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      correct,
    );
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    // 解锁成功:锁屏消失,回到登录页。
    expect(find.text('应用已锁定'), findsNothing);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets('用主密码解锁:错误密码不解锁并显示持久错误提示', (tester) async {
    await seedLockedApp();
    await openMasterDialog(tester);

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'wrong',
    );
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    // 仍处于锁定,且有明确错误提示(不再是静默无反应)。
    expect(find.text('应用已锁定'), findsOneWidget);
    expect(find.text('主密码错误,请重试'), findsOneWidget);
  });

  testWidgets('用主密码解锁:对话框显示主密码提示语', (tester) async {
    await seedLockedApp();
    // 设置提示语后,锁屏主界面与弹窗都应展示(帮助回忆,不暴露密码)。
    await SecureStore().saveMasterHint('我家的保险箱号码');

    await tester.pumpWidget(const BequestApp());
    await tester.pumpAndSettle();
    expect(find.text('应用已锁定'), findsOneWidget);
    expect(find.text('主密码提示: 我家的保险箱号码'), findsOneWidget);

    await tester.ensureVisible(find.text('用主密码解锁'));
    await tester.tap(find.text('用主密码解锁'));
    await tester.pumpAndSettle();
    expect(find.text('请输入主密码'), findsOneWidget);
    expect(find.text('主密码提示: 我家的保险箱号码'), findsNWidgets(2));
  });

  testWidgets('用主密码解锁:本地账户提示语兜底(标准槽为空)', (tester) async {
    await seedLockedApp();
    final store = SecureStore();
    // 模拟旧版本地账户:提示语只在账户槽,标准槽为空。
    // 标准槽已被 seedLockedApp 写入 MK/salt,再登记本地账户并激活。
    await store.createLocalProfile(
      id: 'legacy-local',
      name: '本地账户',
      masterKey: await store.readMasterKey() ?? '',
      salt: await store.readMasterSalt() ?? salt,
      wrappingKey: await store.readWrappingKey() ?? '',
      hint: '本地保险箱提示',
    );
    // 清空标准槽 hint,模拟旧版未同步状态。
    await store.saveMasterHint('');

    await openMasterDialog(tester);
    expect(find.text('请输入主密码'), findsOneWidget);
    // 主界面与对话框各显示一条。
    expect(find.text('主密码提示: 本地保险箱提示'), findsNWidgets(2));
  });

  testWidgets('跳过按钮:本地模式点击后回登录页并清应用锁', (tester) async {
    await seedLockedApp();
    final store = SecureStore();
    // 模拟本地模式:无 JWT、有本地账户(标准槽 = 本地账户密钥)。
    await store.createLocalProfile(
      id: 'skip-local',
      name: '本地账户',
      masterKey: await store.readMasterKey() ?? '',
      salt: await store.readMasterSalt() ?? salt,
      wrappingKey: await store.readWrappingKey() ?? '',
      hint: '',
    );
    await store.saveStorageMode('local');
    // 清 JWT 模拟未登录(seedLockedApp 未存 JWT,天然无)。

    await tester.pumpWidget(const BequestApp());
    await tester.pumpAndSettle();
    expect(find.text('应用已锁定'), findsOneWidget);
    expect(find.text('跳过(退出本地模式)'), findsOneWidget);

    await tester.ensureVisible(find.text('跳过(退出本地模式)'));
    await tester.tap(find.text('跳过(退出本地模式)'));
    await tester.pumpAndSettle();

    // 回到登录页,锁屏消失,应用锁被清除。
    expect(find.text('应用已锁定'), findsNothing);
    expect(find.text('登录'), findsOneWidget);
    expect(await store.readLockEnabled(), isFalse);
    expect(await store.readPinHash(), isNull);
    // 本地账户数据保留。
    expect((await store.readLocalProfiles()).length, 1);
  });
}

import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/main.dart';

void main() {
  testWidgets('应用启动后显示登录页', (WidgetTester tester) async {
    await tester.pumpWidget(const BequestApp());

    expect(find.text('登录'), findsOneWidget);
    expect(find.text('用户名/邮箱'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bequest/widgets/pattern_lock.dart';

/// 3x3 网格内第 i 个点的屏幕坐标(点在各自格子中央)。
Offset dotOffset(Rect rect, int i) {
  const per = 3;
  return rect.topLeft +
      Offset(
        (i % per + 0.5) * rect.width / per,
        (i ~/ per + 0.5) * rect.height / per,
      );
}

Widget host(ValueChanged<List<int>> onCompleted) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 300,
        height: 300,
        child: PatternLock(onCompleted: onCompleted),
      ),
    ),
  ),
);

void main() {
  testWidgets('拖动 3 个圆点,松手回调按顺序的点序', (tester) async {
    final completed = <List<int>>[];
    await tester.pumpWidget(host(completed.add));

    final rect = tester.getRect(find.byType(PatternLock));
    final gesture = await tester.startGesture(dotOffset(rect, 0));
    await tester.pump();
    await gesture.moveTo(dotOffset(rect, 1));
    await tester.pump();
    await gesture.moveTo(dotOffset(rect, 2));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(completed, hasLength(1));
    expect(completed.first, [0, 1, 2]);
  });

  testWidgets('松手后控件清空,可再次绘制同一序列', (tester) async {
    final completed = <List<int>>[];
    await tester.pumpWidget(host(completed.add));

    final rect = tester.getRect(find.byType(PatternLock));
    Future<void> draw(List<int> dots) async {
      final gesture = await tester.startGesture(dotOffset(rect, dots.first));
      await tester.pump();
      for (final i in dots.skip(1)) {
        await gesture.moveTo(dotOffset(rect, i));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
    }

    await draw([0, 4, 8]);
    await draw([0, 4, 8]);

    expect(completed, hasLength(2));
    expect(completed[0], [0, 4, 8]);
    expect(completed[1], [0, 4, 8]);
  });

  testWidgets('未命中圆点的拖动不产生点序', (tester) async {
    final completed = <List<int>>[];
    await tester.pumpWidget(host(completed.add));

    final rect = tester.getRect(find.byType(PatternLock));
    // 在角落空白处按下并抬起,不经过任何圆点。
    final gesture = await tester.startGesture(
      rect.topLeft + const Offset(4, 4),
    );
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(completed, isEmpty);
  });

  testWidgets('快速斜向拖动一步跨过圆点,线段检测完整捕获点序', (tester) async {
    final completed = <List<int>>[];
    await tester.pumpWidget(host(completed.add));

    final rect = tester.getRect(find.byType(PatternLock));
    // 0 → 2 一步到位:手指从未经过点 1,但拖动线段穿过点 1 中心,
    // 段检测应补上 [0, 1, 2] 完整序列。
    final gesture = await tester.startGesture(dotOffset(rect, 0));
    await tester.pump();
    await gesture.moveTo(dotOffset(rect, 2));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(completed, hasLength(1));
    expect(completed.first, [0, 1, 2]);
  });

  testWidgets('快速斜对角拖动一步跨过中心点,捕获 [0,4,8]', (tester) async {
    final completed = <List<int>>[];
    await tester.pumpWidget(host(completed.add));

    final rect = tester.getRect(find.byType(PatternLock));
    final gesture = await tester.startGesture(dotOffset(rect, 0));
    await tester.pump();
    await gesture.moveTo(dotOffset(rect, 8));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(completed, hasLength(1));
    expect(completed.first, [0, 4, 8]);
  });
}

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 3x3 图案锁控件:拖动连接圆点,松手时按顺序回调已选点索引(0..8,行优先)。
///
/// 自包含:绘制、命中与手势全在此处;校验由调用方负责。
/// 拖动时按"上一已选点 → 手指位置"线段做圆点命中检测,快速拖过也能完整捕获点序。
class PatternLock extends StatefulWidget {
  const PatternLock({
    super.key,
    this.dotsPerRow = 3,
    this.activeColor,
    this.onCompleted,
  });

  final int dotsPerRow;
  final Color? activeColor;

  /// 松手时回调按顺序选中的点索引列表;回调后自动清空重绘。
  final ValueChanged<List<int>>? onCompleted;

  @override
  State<PatternLock> createState() => _PatternLockState();
}

class _PatternLockState extends State<PatternLock> {
  final List<int> _selected = [];
  Offset? _current;

  int get _count => widget.dotsPerRow * widget.dotsPerRow;

  /// 命中半径:不小于 28px,且随控件尺寸缩放,拖动更跟手。
  double _hitRadius(double size) {
    final dotRadius = size / (widget.dotsPerRow * 8);
    return math.max(dotRadius * 3.5, 28);
  }

  Offset _center(int index, double size) {
    final per = widget.dotsPerRow;
    return Offset(
      (index % per + 0.5) * size / per,
      (index ~/ per + 0.5) * size / per,
    );
  }

  int? _dotAt(Offset pos, double size) {
    final hitRadius = _hitRadius(size);
    for (var i = 0; i < _count; i++) {
      if ((_center(i, size) - pos).distance <= hitRadius) return i;
    }
    return null;
  }

  /// 点 [p] 在线段 a→b 上的投影参数 t(0..1),越靠近 a 越小。
  double _projT(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.distanceSquared;
    if (len2 == 0) return 0;
    return ((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2;
  }

  /// 点 [p] 到线段 a→b 的最短距离。
  double _distToSegment(Offset p, Offset a, Offset b) {
    final t = _projT(p, a, b).clamp(0.0, 1.0);
    return (p - (a + (b - a) * t)).distance;
  }

  void _addDot(Offset pos, double size) {
    final i = _dotAt(pos, size);
    if (i == null || _selected.contains(i)) return;
    setState(() => _selected.add(i));
  }

  /// 拖动:手指所在点直接命中 → 选中;同时检查"上一已选点 → 手指"线段
  /// 穿过的所有未选点(按沿线段顺序),快速斜向拖动也能完整捕获。
  void _onDrag(Offset pos, double size) {
    setState(() => _current = pos);
    if (_selected.isEmpty) {
      _addDot(pos, size);
      return;
    }
    final hitRadius = _hitRadius(size);
    final from = _center(_selected.last, size);
    final candidates = <int>[
      for (var i = 0; i < _count; i++)
        if (!_selected.contains(i) && _distToSegment(_center(i, size), from, pos) <= hitRadius)
          i,
    ];
    if (candidates.isEmpty) return;
    // 手指位置是线段终点,终点附近的点(直接命中)投影 t≈1,自然排在最后。
    candidates.sort(
      (a, b) => _projT(_center(a, size), from, pos).compareTo(
        _projT(_center(b, size), from, pos),
      ),
    );
    setState(() => _selected.addAll(candidates));
  }

  void _complete() {
    final sequence = List<int>.from(_selected);
    setState(() {
      _selected.clear();
      _current = null;
    });
    if (sequence.isNotEmpty) widget.onCompleted?.call(sequence);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.activeColor ?? Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest.shortestSide;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (d) => _addDot(d.localPosition, size),
          onPanStart: (d) => _addDot(d.localPosition, size),
          onPanUpdate: (d) => _onDrag(d.localPosition, size),
          onPanEnd: (_) => _complete(),
          onPanCancel: _complete,
          child: CustomPaint(
            size: Size.square(size),
            painter: _PatternPainter(
              dotsPerRow: widget.dotsPerRow,
              selected: _selected,
              current: _current,
              activeColor: active,
            ),
          ),
        );
      },
    );
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter({
    required this.dotsPerRow,
    required this.selected,
    required this.current,
    required this.activeColor,
  });

  final int dotsPerRow;
  final List<int> selected;
  final Offset? current;
  final Color activeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final per = dotsPerRow;
    final dotRadius = size.width / (per * 8);
    final centers = [
      for (var i = 0; i < per * per; i++)
        Offset(
          (i % per + 0.5) * size.width / per,
          (i ~/ per + 0.5) * size.height / per,
        ),
    ];
    final line = Paint()
      ..color = activeColor
      ..strokeWidth = dotRadius * 0.8
      ..strokeCap = StrokeCap.round;
    if (selected.length >= 2) {
      for (var i = 0; i < selected.length - 1; i++) {
        canvas.drawLine(centers[selected[i]], centers[selected[i + 1]], line);
      }
    }
    if (current != null && selected.isNotEmpty) {
      canvas.drawLine(centers[selected.last], current!, line);
    }
    for (var i = 0; i < per * per; i++) {
      final isSelected = selected.contains(i);
      canvas.drawCircle(
        centers[i],
        dotRadius,
        Paint()..color = isSelected ? activeColor : Colors.transparent,
      );
      canvas.drawCircle(
        centers[i],
        dotRadius,
        Paint()
          ..color = isSelected
              ? activeColor
              : activeColor.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_PatternPainter oldDelegate) =>
      oldDelegate.selected != selected ||
      oldDelegate.current != current ||
      oldDelegate.activeColor != activeColor ||
      oldDelegate.dotsPerRow != dotsPerRow;
}

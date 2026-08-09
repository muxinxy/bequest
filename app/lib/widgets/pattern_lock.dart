import 'package:flutter/material.dart';

/// 3x3 图案锁控件:拖动连接圆点,松手时按顺序回调已选点索引(0..8,行优先)。
///
/// 自包含:绘制、命中与手势全在此处;校验由调用方负责。
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

  Offset _center(int index, double size) {
    final per = widget.dotsPerRow;
    return Offset(
      (index % per + 0.5) * size / per,
      (index ~/ per + 0.5) * size / per,
    );
  }

  int? _dotAt(Offset pos, double size) {
    final hitRadius = size / (widget.dotsPerRow * 3.2); // 略大于半格距,选中更顺手
    for (var i = 0; i < _count; i++) {
      if ((_center(i, size) - pos).distance <= hitRadius) return i;
    }
    return null;
  }

  void _addDot(Offset pos, double size) {
    final i = _dotAt(pos, size);
    if (i == null || _selected.contains(i)) return;
    setState(() => _selected.add(i));
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
          onPanUpdate: (d) {
            setState(() => _current = d.localPosition);
            _addDot(d.localPosition, size);
          },
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

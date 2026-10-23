import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';

/// 112 px ring: track #2A2A2A, amber round-cap progress, width 10.
class ProgressRing extends StatelessWidget {
  const ProgressRing({super.key, required this.fraction, this.size = 112});

  final double fraction;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Backup progress ${(fraction * 100).round()} percent',
      child: CustomPaint(
        size: Size.square(size),
        painter: _RingPainter(fraction.clamp(0.0, 1.0)),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.fraction);
  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 10.0;
    final rect = (Offset.zero & size).deflate(w / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = Tokens.line);
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * fraction,
        false,
        paint..color = Tokens.accent,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.fraction != fraction;
}

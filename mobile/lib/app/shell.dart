import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'theme/tokens.dart';
import 'theme/typography.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          color: Tokens.navBackground,
          border: Border(top: BorderSide(color: Tokens.navBorder)),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            children: [
              for (final (i, tab) in _tabs.indexed)
                Expanded(
                  child: _NavItem(
                    tab: tab,
                    active: navigationShell.currentIndex == i,
                    onTap: () => navigationShell.goBranch(
                      i,
                      initialLocation: i == navigationShell.currentIndex,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _Draw = void Function(Canvas canvas, Paint paint);

class _Tab {
  const _Tab(this.label, this.draw);
  final String label;
  final _Draw draw;
}

const _tabs = <_Tab>[
  _Tab('Photos', _drawPhotos),
  _Tab('Backup', _drawBackup),
  _Tab('Settings', _drawSettings),
];

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  final _Tab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? Tokens.accent : Tokens.muted;
    return Semantics(
      button: true,
      selected: active,
      label: tab.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CustomPaint(
                size: const Size(22, 22),
                painter: _IconPainter(color, tab.draw),
              ),
              const SizedBox(height: 4),
              Text(
                tab.label,
                style: bodyStyle(
                  size: 12,
                  weight: active ? 600 : 500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.color, this.draw);
  final Color color;
  final _Draw draw;

  @override
  void paint(Canvas canvas, Size size) {
    // Icons are authored on a 24-unit grid, scaled to the 22px box.
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8 * 24 / 22
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    draw(canvas, paint);
  }

  @override
  bool shouldRepaint(_IconPainter old) => old.color != color;
}

void _drawPhotos(Canvas c, Paint p) {
  for (final o in const [
    Offset(3, 3),
    Offset(13, 3),
    Offset(3, 13),
    Offset(13, 13),
  ]) {
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(o.dx, o.dy, 8, 8),
        const Radius.circular(2),
      ),
      p,
    );
  }
}

void _drawBackup(Canvas c, Paint p) {
  c.drawLine(const Offset(12, 15), const Offset(12, 4), p);
  c.drawPath(
    Path()
      ..moveTo(7.5, 8.5)
      ..lineTo(12, 4)
      ..lineTo(16.5, 8.5),
    p,
  );
  c.drawPath(
    Path()
      ..moveTo(4, 14)
      ..lineTo(4, 19)
      ..quadraticBezierTo(4, 20, 5, 20)
      ..lineTo(19, 20)
      ..quadraticBezierTo(20, 20, 20, 19)
      ..lineTo(20, 14),
    p,
  );
}

void _drawSettings(Canvas c, Paint p) {
  c.drawCircle(const Offset(12, 12), 3, p);
  final path = Path();
  const teeth = 8;
  for (var i = 0; i < teeth; i++) {
    final a = i * math.pi * 2 / teeth;
    final dx = math.sin(a), dy = -math.cos(a);
    path.moveTo(12 + dx * 7.2, 12 + dy * 7.2);
    path.lineTo(12 + dx * 9.5, 12 + dy * 9.5);
  }
  c.drawPath(path, p);
  c.drawCircle(const Offset(12, 12), 7.2, p);
}

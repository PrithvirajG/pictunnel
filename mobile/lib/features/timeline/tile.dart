import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart' show ItemState;
import '../../core/thumbs/thumb_image.dart';
import 'timeline_model.dart';

/// Which presence badge a tile shows (M§7.1): a needs-attention dot wins over
/// the amber up-arrow for queued/uploading items, which wins over the cloud
/// of a server-only item.
enum TileBadge { none, attention, uploading, serverOnly }

TileBadge badgeFor(TimelineItem item) {
  switch (item.phoneState) {
    case ItemState.needsAttention:
      return TileBadge.attention;
    case ItemState.queued:
    case ItemState.uploading:
    case ItemState.verifying:
      return TileBadge.uploading;
    default:
      break;
  }
  return item.presence == Presence.serverOnly
      ? TileBadge.serverOnly
      : TileBadge.none;
}

/// `0:14`, `12:03`, `1:02:03`.
String formatDuration(int ms) {
  final s = (ms / 1000).round();
  final h = s ~/ 3600, m = s % 3600 ~/ 60, sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

int? durationMsOf(TimelineItem item) =>
    item.phone?.durationMs ?? item.server?.durationMs;

class TimelineTile extends StatelessWidget {
  const TimelineTile({
    super.key,
    required this.item,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final TimelineItem item;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final badge = badgeFor(item);
    final dur = item.isVideo ? durationMsOf(item) : null;
    return Semantics(
      button: true,
      selected: selected,
      label: _label(badge),
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ThumbImage(item),
            if (selected)
              const ColoredBox(
                key: Key('selectedScrim'),
                color: Color(0x66111111),
              ),
            if (dur != null)
              Positioned(
                left: 6,
                bottom: 6,
                child: _Pill(formatDuration(dur), key: const Key('videoBadge')),
              )
            else if (item.isLive)
              const Positioned(
                left: 6,
                bottom: 6,
                child: _Pill('LIVE', key: Key('liveBadge')),
              ),
            if (badge != TileBadge.none)
              Positioned(
                right: 6,
                bottom: 6,
                child: _Circle(
                  key: Key('badge-${badge.name}'),
                  child: switch (badge) {
                    TileBadge.attention => const _Dot(),
                    TileBadge.uploading => const _Icon(
                      _drawArrowUp,
                      Tokens.accent,
                    ),
                    _ => const _Icon(_drawCloud, Colors.white),
                  },
                ),
              ),
            if (selecting)
              Positioned(
                left: 6,
                top: 6,
                child: _Circle(
                  key: Key(selected ? 'checked' : 'unchecked'),
                  fill: selected ? Tokens.accent : const Color(0x40111111),
                  border: selected ? null : Colors.white,
                  child: selected
                      ? const _Icon(_drawCheck, Tokens.ground)
                      : const SizedBox.shrink(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _label(TileBadge badge) {
    final kind = item.isVideo ? 'Video' : 'Photo';
    final where = switch (badge) {
      TileBadge.attention => 'needs attention',
      TileBadge.uploading => 'uploading',
      TileBadge.serverOnly => 'not on this phone',
      TileBadge.none => 'backed up',
    };
    return '$kind, $where';
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xB3111111),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(text, style: bodyStyle(size: 11, weight: 600)),
    ),
  );
}

class _Circle extends StatelessWidget {
  const _Circle({
    super.key,
    required this.child,
    this.fill = const Color(0xBF111111),
    this.border,
  });

  final Widget child;
  final Color fill;
  final Color? border;

  @override
  Widget build(BuildContext context) => Container(
    width: 22,
    height: 22,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: fill,
      shape: BoxShape.circle,
      border: border == null ? null : Border.all(color: border!, width: 1.5),
    ),
    child: child,
  );
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: const BoxDecoration(
      color: Tokens.accent,
      shape: BoxShape.circle,
    ),
  );
}

typedef _Draw = void Function(Canvas canvas, Paint paint);

class _Icon extends StatelessWidget {
  const _Icon(this.draw, this.color);
  final _Draw draw;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(12, 12), painter: _IconPainter(draw, color));
}

class _IconPainter extends CustomPainter {
  _IconPainter(this.draw, this.color, [this.strokeWidth = 2.6]);
  final _Draw draw;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    draw(
      canvas,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_IconPainter old) =>
      old.color != color || old.draw != draw || old.strokeWidth != strokeWidth;
}

void _drawArrowUp(Canvas c, Paint p) {
  c.drawLine(const Offset(12, 20), const Offset(12, 4), p);
  c.drawPath(
    Path()
      ..moveTo(5, 11)
      ..lineTo(12, 4)
      ..lineTo(19, 11),
    p,
  );
}

void _drawCheck(Canvas c, Paint p) {
  c.drawPath(
    Path()
      ..moveTo(5, 12.5)
      ..lineTo(10, 17.5)
      ..lineTo(19, 7),
    p,
  );
}

void _drawCloud(Canvas c, Paint p) {
  c.drawPath(
    Path()
      ..moveTo(7.5, 18)
      ..cubicTo(4.5, 18, 3, 16, 3, 13.8)
      ..cubicTo(3, 11.8, 4.5, 10.3, 6.5, 10.1)
      ..cubicTo(7, 7.5, 9.2, 5.5, 12, 5.5)
      ..cubicTo(15, 5.5, 17, 7.6, 17.3, 10.2)
      ..cubicTo(19.4, 10.4, 21, 12, 21, 14.2)
      ..cubicTo(21, 16.4, 19.4, 18, 17.2, 18)
      ..close(),
    p,
  );
}

/// Icon painters shared with the screen header and selection bar.
void drawCloudIcon(Canvas c, Paint p) => _drawCloud(c, p);

void drawCheckCircleIcon(Canvas c, Paint p) {
  c.drawCircle(const Offset(12, 12), 9, p);
  _drawCheck(c, p);
}

void drawDownloadIcon(Canvas c, Paint p) {
  c.drawLine(const Offset(12, 4), const Offset(12, 15), p);
  c.drawPath(
    Path()
      ..moveTo(7, 10.5)
      ..lineTo(12, 15.5)
      ..lineTo(17, 10.5),
    p,
  );
  c.drawLine(const Offset(5, 20), const Offset(19, 20), p);
}

void drawTrashIcon(Canvas c, Paint p) {
  c.drawLine(const Offset(4, 7), const Offset(20, 7), p);
  c.drawPath(
    Path()
      ..moveTo(6.5, 7)
      ..lineTo(7.5, 20)
      ..lineTo(16.5, 20)
      ..lineTo(17.5, 7)
      ..moveTo(9.5, 7)
      ..lineTo(9.5, 4)
      ..lineTo(14.5, 4)
      ..lineTo(14.5, 7),
    p,
  );
}

void drawFreeUpIcon(Canvas c, Paint p) {
  c.drawRRect(
    RRect.fromRectAndRadius(
      const Rect.fromLTWH(7, 3, 10, 18),
      const Radius.circular(2.5),
    ),
    p,
  );
  c.drawLine(const Offset(11, 18), const Offset(13, 18), p);
}

void drawCloseIcon(Canvas c, Paint p) {
  c.drawLine(const Offset(6, 6), const Offset(18, 18), p);
  c.drawLine(const Offset(18, 6), const Offset(6, 18), p);
}

/// A stroke icon on the shared 24-unit grid, drawn at [size].
class StrokeIcon extends StatelessWidget {
  const StrokeIcon(
    this.draw, {
    super.key,
    this.color = Tokens.text,
    this.size = 22,
  });

  final void Function(Canvas, Paint) draw;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(size, size),
    painter: _IconPainter(draw, color, 1.8 * 24 / size),
  );
}

import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import 'tile.dart';
import 'timeline_layout.dart';
import 'timeline_model.dart';

const timelineGap = 2.0;
const timelineHeaderHeight = 52.0;

/// The header row extent for the current text scale: 52 at 100%, growing
/// with the scaled 17px title (with line-height headroom) so a 200% font
/// still fits the fixed-extent row (M§7.2).
double timelineHeaderExtent(TextScaler scaler) {
  final grow = scaler.scale(17) - 17;
  return grow <= 0 ? timelineHeaderHeight : timelineHeaderHeight + grow * 1.5;
}

/// "October 2026" (17/600) with a right-aligned 13px caption.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.row, {super.key});

  final HeaderRow row;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(
            row.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: bodyStyle(size: 17, weight: 600),
          ),
        ),
        Text(row.caption, style: bodyStyle(size: 13, color: Tokens.muted)),
      ],
    ),
  );
}

/// One row of square tiles; [tileSize] is fixed so a short last row keeps the
/// grid alignment.
class TileRowView extends StatelessWidget {
  const TileRowView({
    super.key,
    required this.row,
    required this.tileSize,
    required this.selecting,
    required this.selectedKeys,
    required this.onTap,
    required this.onLongPress,
  });

  final TilesRow row;
  final double tileSize;
  final bool selecting;
  final Set<String> selectedKeys;
  final void Function(TimelineItem item) onTap;
  final void Function(TimelineItem item) onLongPress;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: timelineGap),
    child: Row(
      children: [
        for (final (i, item) in row.items.indexed) ...[
          if (i > 0) const SizedBox(width: timelineGap),
          SizedBox(
            width: tileSize,
            height: tileSize,
            child: TimelineTile(
              key: ValueKey(item.key),
              item: item,
              selecting: selecting,
              selected: selectedKeys.contains(item.key),
              onTap: () => onTap(item),
              onLongPress: () => onLongPress(item),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Muted squares for a month that is still loading.
class PlaceholderRowView extends StatelessWidget {
  const PlaceholderRowView({
    super.key,
    required this.row,
    required this.tileSize,
  });

  final PlaceholderRow row;
  final double tileSize;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: timelineGap),
    child: Row(
      children: [
        for (var i = 0; i < row.count; i++) ...[
          if (i > 0) const SizedBox(width: timelineGap),
          SizedBox(
            width: tileSize,
            height: tileSize,
            child: const ColoredBox(color: Tokens.surface),
          ),
        ],
      ],
    ),
  );
}

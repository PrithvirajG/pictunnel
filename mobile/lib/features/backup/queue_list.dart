import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import 'upload_card.dart';

final _when = DateFormat('MMM d, HH:mm');

class QueueList extends StatelessWidget {
  const QueueList({super.key, required this.items, required this.waitingNote});

  final List<PhoneItem> items;

  /// State text under each name, e.g. "Waiting" or "Waiting for Wi-Fi".
  final String waitingNote;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const Key('upNext'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'UP NEXT',
          style: bodyStyle(
            size: 13,
            weight: 600,
            color: Tokens.muted,
          ).copyWith(letterSpacing: 13 * 0.06),
        ),
        const SizedBox(height: 4),
        for (final item in items)
          Container(
            height: 52,
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFF222222))),
            ),
            child: Row(
              children: [
                PhoneThumb(localId: item.localId, size: 36, radius: 8),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.filename.isEmpty ? _fallbackName(item) : item.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: bodyStyle(size: 15),
                  ),
                ),
                Text(
                  waitingNote,
                  style: bodyStyle(size: 13, color: Tokens.muted),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Shown when the platform knows no file name: kind and date.
  String _fallbackName(PhoneItem i) {
    final kind = i.mime.startsWith('video/') ? 'Video' : 'Photo';
    return '$kind · ${_when.format(DateTime.fromMillisecondsSinceEpoch(i.takenAtMs))}';
  }
}

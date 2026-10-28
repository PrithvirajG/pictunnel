import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../backup/format.dart';
import '../timeline/timeline_model.dart';
import 'viewer_actions.dart';

/// "38.72° N, 9.14° W".
String formatCoordinates(double lat, double lon) {
  String one(double v, String pos, String neg) =>
      '${v.abs().toStringAsFixed(2)}° ${v < 0 ? neg : pos}';
  return '${one(lat, 'N', 'S')}, ${one(lon, 'E', 'W')}';
}

/// "4032 × 3024 · 3.2 MB"; parts that are unknown are left out.
String formatSizeRow(int? width, int? height, int? bytes) => [
  if (width != null && height != null) '$width × $height',
  ?(bytes == null ? null : formatBytes(bytes)),
].join(' · ');

/// The file facts under the photo: File, Size, Location and Folder, in a
/// grid with a 96px label column.
class InfoPanel extends ConsumerWidget {
  const InfoPanel({super.key, required this.item});

  final TimelineItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = item.server;
    final phone = item.phone;
    final detail = server == null
        ? null
        : ref.watch(assetDetailProvider(server.id)).value;
    final owner = ref.watch(libraryOwnerProvider);

    final filename = server?.filename ?? phone?.filename;
    final size = formatSizeRow(
      server?.width ?? phone?.width,
      server?.height ?? phone?.height,
      server?.sizeBytes ?? phone?.size,
    );
    final lat = detail?.lat, lon = detail?.lon;
    final rows = <(String, String, bool)>[
      if (filename != null) ('File', filename, false),
      if (size.isNotEmpty) ('Size', size, true),
      if (lat != null && lon != null)
        ('Location', formatCoordinates(lat, lon), true),
      if (server != null)
        (
          'Folder',
          [
            ?owner,
            '${server.year}',
            server.month.toString().padLeft(2, '0'),
          ].join(' / '),
          false,
        ),
    ];
    return Column(
      key: const Key('infoPanel'),
      children: [for (final r in rows) _InfoRow(r.$1, r.$2, tabular: r.$3)],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {required this.tabular});

  final String label;
  final String value;
  final bool tabular;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(label, style: bodyStyle(size: 14, color: Tokens.muted)),
        ),
        Expanded(
          child: Text(
            value,
            style: bodyStyle(size: 14).copyWith(
              fontFeatures: tabular
                  ? const [FontFeature.tabularFigures()]
                  : null,
            ),
          ),
        ),
      ],
    ),
  );
}

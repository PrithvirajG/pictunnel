import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import 'backup_providers.dart';
import 'format.dart';

/// Square local thumbnail; a tonal placeholder while loading or when empty.
class PhoneThumb extends ConsumerWidget {
  const PhoneThumb({
    super.key,
    required this.localId,
    required this.size,
    required this.radius,
  });

  final String localId;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(phoneThumbProvider(localId)).value;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: bytes == null || bytes.isEmpty
            ? const ColoredBox(color: Tokens.line)
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      ),
    );
  }
}

class UploadCard extends StatelessWidget {
  const UploadCard({super.key, required this.upload});

  final UploadProgress upload;

  @override
  Widget build(BuildContext context) {
    final muted = bodyStyle(size: 13, color: Tokens.muted);
    final fraction = upload.totalBytes > 0
        ? (upload.sentBytes / upload.totalBytes).clamp(0.0, 1.0)
        : 0.0;
    return Container(
      key: const Key('uploadCard'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Tokens.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhoneThumb(localId: upload.localId, size: 52, radius: 10),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Uploading ${upload.filename}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: bodyStyle(size: 15, weight: 600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatSentOfTotal(upload.sentBytes, upload.totalBytes)}'
                      ' · ${formatSpeed(upload.bytesPerSecond)}',
                      style: muted.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: Tokens.line,
              valueColor: const AlwaysStoppedAnimation(Tokens.accent),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'If the connection drops, it picks up where it left off.',
            style: muted,
          ),
        ],
      ),
    );
  }
}

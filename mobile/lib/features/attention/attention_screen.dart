import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import '../../core/engine/error_copy.dart';
import '../backup/backup_providers.dart';

/// User-facing copy per problem code (spec M§8, P§8). Unknown codes fall back
/// to the engine's own message.
const problemCopy = <String, String>{
  'insufficient_storage': 'Your server is out of space. Backup is paused.',
  'quota_exceeded': 'Your storage limit on the server is reached.',
  'file_too_large': 'This file is larger than your server accepts.',
  'invalid_request': "The server couldn't accept this file.",
  'length_mismatch': 'The file changed while uploading. Try again.',
  'checksum_mismatch': 'The upload arrived damaged. Try again.',
  'client_too_old': 'Update PicTunnel to back this up.',
  'forbidden': "This account isn't allowed to upload this file.",
  'tombstoned':
      'You deleted this from your server, so PicTunnel skips it.',
};

String attentionReason(AttentionItem i) =>
    problemCopy[i.code] ?? (i.message.isEmpty ? i.code : i.message);

class AttentionScreen extends ConsumerWidget {
  const AttentionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(attentionProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('Needs attention', style: displayStyle(size: 20)),
      ),
      body: items.when(
        loading: () => const SizedBox.shrink(),
        error: (_, _) => const SizedBox.shrink(),
        data: (list) => list.isEmpty
            ? Center(
                child: Text(
                  'Nothing needs your attention.',
                  key: const Key('attentionEmpty'),
                  style: bodyStyle(size: 15, color: Tokens.muted),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [for (final i in list) _Row(item: i)],
              ),
      ),
    );
  }
}

class _Row extends ConsumerWidget {
  const _Row({required this.item});
  final AttentionItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Skipped (tombstoned) items carry their hash: offer "Back up again".
    final sha = item.sha256;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF222222))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: bodyStyle(size: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  attentionReason(item),
                  style: bodyStyle(size: 13, color: Tokens.muted),
                ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: Tokens.accent,
            ),
            onPressed: () async {
              final engine = ref.read(engineProvider);
              final messenger = ScaffoldMessenger.maybeOf(context);
              try {
                if (sha != null) {
                  await engine.undoSkip(sha);
                } else {
                  await engine.retry([item.localId]);
                }
              } catch (e) {
                messenger?.showSnackBar(
                  SnackBar(content: Text(engineErrorMessage(e))),
                );
              }
              ref.invalidate(attentionProvider);
            },
            child: Text(
              sha != null ? 'Back up again' : 'Retry',
              style: bodyStyle(size: 14, weight: 700, color: Tokens.accent),
            ),
          ),
        ],
      ),
    );
  }
}

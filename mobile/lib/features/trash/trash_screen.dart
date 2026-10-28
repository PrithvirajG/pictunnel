import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pictunnel_api/pictunnel_api.dart' as api;

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/db/app_db.dart';
import '../../core/db/server_assets_dao.dart';
import '../../core/thumbs/thumb_image.dart';
import '../backup/format.dart';
import '../timeline/timeline_providers.dart';
import '../viewer/viewer_actions.dart';

/// Trashed server assets, newest first.
final trashedAssetsProvider = StreamProvider.autoDispose<List<ServerAsset>>(
  (ref) => ref.watch(serverAssetsDaoProvider).watchTrashed(),
);

/// Trash (under Settings): trashed server assets with Restore, Delete forever
/// and Empty trash. Everything here acts on the server copy only.
class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});

  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  bool _busy = false;

  Future<void> _run(
    Future<void> Function(api.AssetsApi, ServerAssetsDao) act,
    String done,
  ) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await act(ref.read(assetsApiProvider), ref.read(serverAssetsDaoProvider));
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Something went wrong. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  api.AssetIdList _ids(String id) =>
      api.AssetIdList((b) => b.assetIds.replace([id]));

  Future<void> _restore(ServerAsset a) => _run((client, dao) async {
    final r = await client.restoreAssets(assetIdList: _ids(a.id));
    final ok = r.data?.succeeded.toList() ?? [a.id];
    await dao.setState(ok, 'active');
  }, 'Restored');

  Future<void> _purge(ServerAsset a) async {
    final ok = await _confirm(
      title: 'Delete forever?',
      body:
          'Permanently deletes it from your server. A copy on this phone '
          'stays.',
      action: 'Delete forever',
    );
    if (!ok) return;
    await _run((client, dao) async {
      final r = await client.purgeAssets(assetIdList: _ids(a.id));
      final done = r.data?.succeeded.toList() ?? [a.id];
      for (final id in done) {
        await dao.remove(id);
      }
    }, 'Deleted forever');
  }

  Future<void> _empty() async {
    final ok = await _confirm(
      title: 'Empty trash?',
      body: 'Permanently deletes everything in the Trash from your server.',
      action: 'Empty trash',
    );
    if (!ok) return;
    await _run((client, dao) async {
      await client.emptyTrash();
      await dao.removeTrashed();
    }, 'Trash emptied');
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Tokens.surface,
        title: Text(title, style: displayStyle(size: 20)),
        content: Text(body, style: bodyStyle(size: 15, color: Tokens.muted)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(trashedAssetsProvider).value;
    return Scaffold(
      backgroundColor: Tokens.ground,
      appBar: AppBar(
        backgroundColor: Tokens.ground,
        foregroundColor: Tokens.text,
        title: Text('Trash', style: displayStyle(size: 22)),
        actions: [
          TextButton(
            key: const Key('emptyTrash'),
            onPressed: items == null || items.isEmpty || _busy ? null : _empty,
            child: const Text('Empty trash'),
          ),
        ],
      ),
      body: items == null
          ? const SizedBox.shrink()
          : items.isEmpty
          ? Center(
              child: Text(
                'Trash is empty',
                style: bodyStyle(size: 15, color: Tokens.muted),
              ),
            )
          : ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Text(
                    "Items are removed from your server's Trash after 30 "
                    'days. Copies on this phone are never touched.',
                    style: bodyStyle(size: 13, color: Tokens.muted),
                  ),
                ),
                for (final a in items)
                  _TrashRow(
                    asset: a,
                    busy: _busy,
                    onRestore: () => _restore(a),
                    onPurge: () => _purge(a),
                  ),
              ],
            ),
    );
  }
}

class _TrashRow extends ConsumerWidget {
  const _TrashRow({
    required this.asset,
    required this.busy,
    required this.onRestore,
    required this.onPurge,
  });

  final ServerAsset asset;
  final bool busy;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thumb = ref.watch(serverTileThumbProvider(asset.id)).value;
    return Padding(
      key: Key('trash-${asset.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 56,
              child: thumb == null
                  ? ThumbPlaceholder(asset.id)
                  : Image.file(
                      thumb,
                      fit: BoxFit.cover,
                      cacheWidth: phoneThumbPx,
                      errorBuilder: (_, _, _) => ThumbPlaceholder(asset.id),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  asset.filename,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: bodyStyle(size: 15, weight: 500),
                ),
                Text(
                  formatBytes(asset.sizeBytes),
                  style: bodyStyle(size: 13, color: Tokens.muted),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: busy ? null : onRestore,
            child: const Text('Restore'),
          ),
          TextButton(
            onPressed: busy ? null : onPurge,
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
  }
}

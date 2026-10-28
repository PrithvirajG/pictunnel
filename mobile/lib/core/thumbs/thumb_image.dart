import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../features/timeline/timeline_model.dart';
import '../db/thumb_cache.dart';
import '../engine/engine.dart';

/// Server thumbnail size name requested for grid tiles (M§7.1).
const serverThumbSize = 'thumb';

/// Pixel size asked of the phone for grid tiles.
const phoneThumbPx = 256;

/// Wired by the app composition root once the API client and database exist.
final thumbCacheProvider = Provider<ThumbCache>(
  (ref) => throw UnimplementedError('override thumbCacheProvider'),
);

final phoneTileThumbProvider = FutureProvider.autoDispose
    .family<Uint8List, String>(
      (ref, localId) =>
          ref.watch(engineProvider).phoneThumbnail(localId, phoneThumbPx),
    );

/// The cached server thumbnail, or null while the server has not generated it.
/// A null result retries every [thumbRetryDelay] while the tile is on screen.
final serverTileThumbProvider = FutureProvider.autoDispose
    .family<File?, String>((ref, assetId) async {
      final file = await ref
          .watch(thumbCacheProvider)
          .get(assetId, serverThumbSize);
      if (file == null && ref.mounted) {
        final timer = Timer(thumbRetryDelay, ref.invalidateSelf);
        ref.onDispose(timer.cancel);
      }
      return file;
    });

const thumbRetryDelay = Duration(seconds: 5);

/// Square-filling thumbnail: the phone's own thumbnail for items on the phone
/// (no network), the cached server thumbnail otherwise, a tonal placeholder
/// while loading, not ready or failed.
class ThumbImage extends ConsumerWidget {
  const ThumbImage(this.item, {super.key});

  final TimelineItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeholder = ThumbPlaceholder(item.key);
    final Widget? image = _image(ref);
    if (image == null) return placeholder;
    // The placeholder stays underneath so a tile never flashes empty while
    // the image decodes.
    return Stack(fit: StackFit.expand, children: [placeholder, image]);
  }

  Widget? _image(WidgetRef ref) {
    Widget broken(BuildContext _, Object _, StackTrace? _) =>
        const SizedBox.shrink();
    final phone = item.phone;
    if (phone != null) {
      final bytes = ref.watch(phoneTileThumbProvider(phone.localId)).value;
      if (bytes == null || bytes.isEmpty) return null;
      return Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        cacheWidth: phoneThumbPx,
        errorBuilder: broken,
      );
    }
    final server = item.server;
    if (server == null) return null;
    final file = ref.watch(serverTileThumbProvider(server.id)).value;
    if (file == null) return null;
    return Image.file(
      file,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      cacheWidth: phoneThumbPx,
      errorBuilder: broken,
    );
  }
}

/// A stable tonal square derived from [seed], close to the Darkroom surface.
class ThumbPlaceholder extends StatelessWidget {
  const ThumbPlaceholder(this.seed, {super.key});

  final String seed;

  @override
  Widget build(BuildContext context) {
    final shift = (seed.codeUnits.fold<int>(0, (a, b) => a + b) % 7) * 3;
    return ColoredBox(
      key: const Key('thumbPlaceholder'),
      color: Color.lerp(
        Tokens.surface,
        Tokens.line,
        shift / 20,
      )!.withValues(alpha: 1),
    );
  }
}

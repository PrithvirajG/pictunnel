import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';

import '../../app/theme/tokens.dart';
import '../../core/engine/engine.dart';
import '../../core/thumbs/thumb_image.dart';
import '../timeline/timeline_model.dart';
import 'viewer_actions.dart';

/// Server derivative shown first, before the original is fetched on zoom.
const serverPreviewSize = 'preview';

/// Pixel size asked of the phone for the viewer image.
const phoneViewerPx = 2048;

/// Viewer background (Darkroom "Photo viewer").
const viewerGround = Color(0xFF0A0A0A);

/// The server `preview` JPEG, or null while the server has not made it yet.
final previewFileProvider = FutureProvider.autoDispose.family<File?, String>(
  (ref, assetId) =>
      ref.watch(thumbCacheProvider).get(assetId, serverPreviewSize),
);

final phoneImageProvider = FutureProvider.autoDispose.family<Uint8List, String>(
  (ref, localId) =>
      ref.watch(engineProvider).phoneThumbnail(localId, phoneViewerPx),
);

/// The server original, fetched only once the person zooms in.
final originalBytesProvider = FutureProvider.autoDispose
    .family<Uint8List?, String>((ref, assetId) async {
      final res = await ref
          .watch(assetsApiProvider)
          .getAssetOriginal(assetId: assetId);
      return res.data;
    });

/// One zoomable photo. Items on this phone show the phone's own image (no
/// network); server-only items show the `preview` first and swap to the
/// original the first time the person zooms.
class PhotoPage extends ConsumerStatefulWidget {
  const PhotoPage({super.key, required this.item});

  final TimelineItem item;

  @override
  ConsumerState<PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends ConsumerState<PhotoPage> {
  bool _zoomed = false;

  @override
  void didUpdateWidget(PhotoPage old) {
    super.didUpdateWidget(old);
    if (old.item.key != widget.item.key) _zoomed = false;
  }

  ImageProvider? _provider() {
    final item = widget.item;
    final phone = item.phone;
    if (phone != null) {
      final bytes = ref.watch(phoneImageProvider(phone.localId)).value;
      return bytes == null || bytes.isEmpty ? null : MemoryImage(bytes);
    }
    final id = item.server?.id;
    if (id == null) return null;
    if (_zoomed) {
      final original = ref.watch(originalBytesProvider(id)).value;
      if (original != null && original.isNotEmpty) {
        return MemoryImage(original);
      }
    }
    final preview =
        ref.watch(previewFileProvider(id)).value ??
        ref.watch(serverTileThumbProvider(id)).value;
    return preview == null ? null : FileImage(preview);
  }

  @override
  Widget build(BuildContext context) {
    final image = _provider();
    if (image == null) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            color: Tokens.muted,
          ),
        ),
      );
    }
    return PhotoView(
      key: const Key('photoView'),
      imageProvider: image,
      gaplessPlayback: true,
      loadingBuilder: (_, _) => const ColoredBox(color: viewerGround),
      backgroundDecoration: const BoxDecoration(color: viewerGround),
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.covered * 4,
      scaleStateChangedCallback: (s) {
        if (s != PhotoViewScaleState.initial && !_zoomed) {
          setState(() => _zoomed = true);
        }
      },
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
    );
  }
}

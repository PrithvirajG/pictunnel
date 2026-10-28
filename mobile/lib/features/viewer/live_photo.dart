import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../timeline/timeline_model.dart';
import 'photo_page.dart';
import 'video_page.dart';

/// A Live Photo: the still, plus its paired video while the person presses
/// and holds. The video streams from the asset's authenticated `playback`
/// URL; items that are not on the server show only the still.
class LivePhotoPage extends ConsumerStatefulWidget {
  const LivePhotoPage({super.key, required this.item});

  final TimelineItem item;

  @override
  ConsumerState<LivePhotoPage> createState() => _LivePhotoPageState();
}

class _LivePhotoPageState extends ConsumerState<LivePhotoPage> {
  VideoPlayerController? _controller;
  int _press = 0;

  Future<void> _start() async {
    final id = widget.item.server?.id;
    if (id == null) return;
    final press = ++_press;
    try {
      final c = await openPlayback(ref, id);
      if (!mounted || press != _press) {
        await c.dispose();
        return;
      }
      await c.setLooping(true);
      await c.play();
      setState(() => _controller = c);
    } catch (_) {
      // The still stays on screen when the clip cannot be loaded.
    }
  }

  void _stop() {
    _press++;
    final c = _controller;
    if (c == null) return;
    setState(() => _controller = null);
    c.dispose();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return GestureDetector(
      key: const Key('livePhoto'),
      onLongPressStart: (_) => _start(),
      onLongPressEnd: (_) => _stop(),
      onLongPressCancel: _stop,
      child: Stack(
        fit: StackFit.expand,
        children: [
          PhotoPage(item: widget.item),
          if (c != null && c.value.isInitialized)
            IgnorePointer(
              child: ColoredBox(
                color: viewerGround,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: c.value.aspectRatio,
                    child: VideoPlayer(c),
                  ),
                ),
              ),
            ),
          const Positioned(left: 12, top: 12, child: _LiveBadge()),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0x99000000),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(
        'LIVE',
        style: bodyStyle(size: 11, weight: 600, color: Tokens.text),
      ),
    ),
  );
}

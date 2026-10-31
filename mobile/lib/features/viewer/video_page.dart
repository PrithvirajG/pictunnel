import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../timeline/timeline_model.dart';
import 'photo_page.dart';
import 'viewer_actions.dart';

/// Builds the controller for an authenticated stream; overridden in tests.
typedef VideoControllerFactory =
    VideoPlayerController Function(Uri url, Map<String, String> headers);

final videoControllerFactoryProvider = Provider<VideoControllerFactory>(
  (_) =>
      (url, headers) => VideoPlayerController.networkUrl(
        url,
        httpHeaders: headers,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      ),
);

/// A player over an open [PlaybackSession]; [dispose] releases both.
class Playback {
  Playback(this.controller, this._session);

  final VideoPlayerController controller;
  final PlaybackSession _session;

  Future<void> dispose() async {
    try {
      await controller.dispose();
    } finally {
      await _session.close();
    }
  }
}

/// Opens the playback stream of [assetId] (through the pinned loopback proxy
/// in the app). The caller owns the result and must [Playback.dispose] it.
Future<Playback> openPlayback(WidgetRef ref, String assetId) async {
  final session = await ref.read(playbackSourceProvider).open(assetId);
  final controller = ref.read(videoControllerFactoryProvider)(
    session.url,
    session.headers,
  );
  final playback = Playback(controller, session);
  try {
    await controller.initialize();
  } catch (_) {
    await playback.dispose();
    rethrow;
  }
  return playback;
}

/// Video over the authenticated `playback` URL (HTTP range streaming), with
/// the server preview as the poster until it is ready to play.
class VideoPage extends ConsumerStatefulWidget {
  const VideoPage({super.key, required this.item});

  final TimelineItem item;

  @override
  ConsumerState<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends ConsumerState<VideoPage> {
  Playback? _playback;
  VideoPlayerController? get _controller => _playback?.controller;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    final id = widget.item.server?.id;
    if (id == null) return;
    try {
      final p = await openPlayback(ref, id);
      if (!mounted) {
        await p.dispose();
        return;
      }
      p.controller.addListener(_tick);
      setState(() => _playback = p);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.removeListener(_tick);
    _playback?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (widget.item.server == null) {
      return const _Note('Plays once it has been backed up');
    }
    if (_failed) return const _Note("Couldn't play this video");
    if (c == null || !c.value.isInitialized) {
      return Stack(
        fit: StackFit.expand,
        children: [
          PhotoPage(item: widget.item),
          const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Tokens.text,
              ),
            ),
          ),
        ],
      );
    }
    final playing = c.value.isPlaying;
    return GestureDetector(
      key: const Key('videoSurface'),
      behavior: HitTestBehavior.opaque,
      onTap: () => playing ? c.pause() : c.play(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio == 0
                  ? 16 / 9
                  : c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
          if (!playing)
            const Center(
              child: Icon(
                Icons.play_circle_outline,
                size: 64,
                color: Tokens.text,
              ),
            ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 8,
            child: VideoProgressIndicator(
              c,
              allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: Tokens.accent,
                bufferedColor: Tokens.line,
                backgroundColor: Tokens.surface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(text, style: bodyStyle(size: 14, color: Tokens.muted)),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import '../timeline/selection.dart';
import '../timeline/tile.dart';
import '../timeline/timeline_model.dart';
import 'info_panel.dart';
import 'live_photo.dart';
import 'photo_page.dart';
import 'video_page.dart';
import 'viewer_actions.dart';

/// Name of the paired server for the status row.
final viewerServerNameProvider = FutureProvider.autoDispose<String>((
  ref,
) async {
  final info = await ref.watch(engineProvider).serverInfo();
  return info?.name ?? 'your server';
});

/// Darkroom "Photo viewer": paged photos and videos with a top bar, a status
/// row, the info list and the Share / Original / Free up / Trash bar.
class ViewerScreen extends ConsumerStatefulWidget {
  const ViewerScreen({super.key, required this.assetKey});

  /// [TimelineItem.key] of the item to open first.
  final String assetKey;

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen> {
  static const photoAreaHeight = 390.0;

  late String _key = widget.assetKey;
  PageController? _pages;
  bool _busy = false;

  @override
  void dispose() {
    _pages?.dispose();
    super.dispose();
  }

  TimelineItem? _current(List<TimelineItem> items) {
    for (final i in items) {
      if (i.key == _key) return i;
    }
    return null;
  }

  void _syncPage(List<TimelineItem> items) {
    final index = items.indexWhere((i) => i.key == _key);
    final c = _pages;
    if (c == null || index < 0 || !c.hasClients) return;
    if (c.page?.round() != index) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && c.hasClients) c.jumpToPage(index);
      });
    }
  }

  Future<void> _run(
    Future<void> Function() act, {
    required String done,
    bool pop = false,
  }) async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await act();
      messenger.showSnackBar(SnackBar(content: Text(done)));
      if (pop && mounted) navigator.maybePop();
    } on ViewerActionException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Something went wrong. Try again.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _trash(TimelineItem item) async {
    final ok = await confirmTrash(context, item);
    if (!ok || !mounted) return;
    await _run(
      () => ref.read(timelineActionsProvider).trash([item]),
      done: 'Moved to trash',
      pop: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(viewerItemsProvider);
    final items = async.value;
    if (items == null) {
      return const Scaffold(
        backgroundColor: viewerGround,
        body: Center(child: CircularProgressIndicator(color: Tokens.muted)),
      );
    }
    final current = _current(items);
    if (current == null) {
      // The item left the timeline (trashed or purged elsewhere).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
      return const Scaffold(backgroundColor: viewerGround);
    }
    final index = items.indexOf(current);
    _pages ??= PageController(initialPage: index);
    _syncPage(items);
    final actions = ref.read(timelineActionsProvider);

    return Scaffold(
      backgroundColor: viewerGround,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(item: current),
            SizedBox(
              height: photoAreaHeight,
              child: PageView.builder(
                key: const Key('viewerPages'),
                controller: _pages,
                itemCount: items.length,
                onPageChanged: (i) => setState(() => _key = items[i].key),
                itemBuilder: (_, i) => _page(items[i]),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  children: [
                    _StatusRow(item: current),
                    const SizedBox(height: 12),
                    InfoPanel(item: current),
                  ],
                ),
              ),
            ),
            _ActionBar(
              item: current,
              busy: _busy,
              onShare: () => _run(
                () => ref
                    .read(shareServiceProvider)
                    .shareOriginal(
                      current.server!.id,
                      current.server!.filename,
                      current.server!.mime,
                    ),
                done: 'Shared',
              ),
              onOriginal: () => _run(
                () => actions.download([current]),
                done: 'Saved to your gallery',
              ),
              onFreeUp: () => _run(
                () => actions.freeUp([current]),
                done: 'Freed up space on this phone',
              ),
              onTrash: () => _trash(current),
            ),
          ],
        ),
      ),
    );
  }

  Widget _page(TimelineItem item) {
    if (item.isVideo) return VideoPage(key: ValueKey(item.key), item: item);
    if (item.isLive) {
      return LivePhotoPage(key: ValueKey(item.key), item: item);
    }
    return PhotoPage(key: ValueKey(item.key), item: item);
  }
}

/// What the Trash action says before it runs (M§7.1: it acts on the server
/// copy only, and the copy says so).
String trashConfirmCopy(TimelineItem item) => item.presence == Presence.both
    ? 'Removes it from your server. It stays on this phone.'
    : "Moves it to your server's Trash for 30 days.";

Future<bool> confirmTrash(BuildContext context, TimelineItem item) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Tokens.surface,
      title: Text('Move to trash?', style: displayStyle(size: 20)),
      content: Text(
        trashConfirmCopy(item),
        style: bodyStyle(size: 15, color: Tokens.muted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Move to trash'),
        ),
      ],
    ),
  );
  return r ?? false;
}

final _dateFormat = DateFormat('EEE d MMM · HH:mm');

class _TopBar extends StatelessWidget {
  const _TopBar({required this.item});
  final TimelineItem item;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: Row(
      children: [
        _RoundButton(
          label: 'Back',
          draw: _drawChevronLeft,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        Expanded(
          child: Text(
            _dateFormat.format(item.takenAt.toLocal()),
            key: const Key('viewerDate'),
            textAlign: TextAlign.center,
            style: bodyStyle(size: 14, color: const Color(0xFFC9C4BB)),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'More',
          color: Tokens.surface,
          icon: const StrokeIcon(_drawMore),
          constraints: const BoxConstraints(minWidth: 44),
          padding: EdgeInsets.zero,
          onSelected: (_) {
            final name = item.server?.filename ?? item.phone?.filename;
            if (name != null) Clipboard.setData(ClipboardData(text: name));
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'copy', child: Text('Copy file name')),
          ],
        ),
      ],
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.label,
    required this.draw,
    required this.onTap,
  });

  final String label;
  final void Function(Canvas, Paint) draw;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    excludeSemantics: true,
    child: InkResponse(
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(child: StrokeIcon(draw)),
      ),
    ),
  );
}

class _StatusRow extends ConsumerWidget {
  const _StatusRow({required this.item});
  final TimelineItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(viewerServerNameProvider).value ?? 'your server';
    final (text, color, draw) = switch (item.presence) {
      Presence.both => (
        'Backed up to $name · also on this phone',
        Tokens.ok,
        drawCheckCircleIcon,
      ),
      Presence.serverOnly => (
        'On $name · not on this phone',
        Tokens.muted,
        drawCloudIcon,
      ),
      Presence.phoneOnly => switch (item.phoneState) {
        ItemState.queued || ItemState.uploading || ItemState.verifying => (
          'Backing up to $name…',
          Tokens.accent,
          drawCloudIcon,
        ),
        ItemState.needsAttention => (
          'Needs attention · not backed up',
          Tokens.accent,
          drawCloudIcon,
        ),
        _ => (
          'Only on this phone · not backed up yet',
          Tokens.muted,
          drawCloudIcon,
        ),
      },
    };
    return DecoratedBox(
      key: const Key('statusRow'),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            StrokeIcon(draw, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: bodyStyle(size: 15))),
          ],
        ),
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.item,
    required this.busy,
    required this.onShare,
    required this.onOriginal,
    required this.onFreeUp,
    required this.onTrash,
  });

  final TimelineItem item;
  final bool busy;
  final VoidCallback onShare;
  final VoidCallback onOriginal;
  final VoidCallback onFreeUp;
  final VoidCallback onTrash;

  @override
  Widget build(BuildContext context) {
    final hasServer = item.server != null;
    return DecoratedBox(
      key: const Key('viewerActions'),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF1F1F1F))),
      ),
      child: Row(
        children: [
          _Action(
            'Share',
            _drawShare,
            enabled: hasServer && !busy,
            onTap: onShare,
          ),
          _Action(
            'Original',
            drawDownloadIcon,
            enabled: downloadable([item]).isNotEmpty && !busy,
            onTap: onOriginal,
          ),
          _Action(
            'Free up',
            drawFreeUpIcon,
            enabled: freeable([item]).isNotEmpty && !busy,
            onTap: onFreeUp,
          ),
          _Action(
            'Trash',
            drawTrashIcon,
            enabled: trashable([item]).isNotEmpty && !busy,
            onTap: onTrash,
          ),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(
    this.label,
    this.draw, {
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final void Function(Canvas, Paint) draw;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Tokens.text : const Color(0xFF6B6760);
    return Expanded(
      child: Semantics(
        button: true,
        enabled: enabled,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          key: Key('action$label'),
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                StrokeIcon(draw, color: color),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: bodyStyle(size: 12, weight: 500, color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void _drawChevronLeft(Canvas c, Paint p) => c.drawPath(
  Path()
    ..moveTo(15, 5)
    ..lineTo(8, 12)
    ..lineTo(15, 19),
  p,
);

void _drawMore(Canvas c, Paint p) {
  final dot = Paint()
    ..color = p.color
    ..style = PaintingStyle.fill;
  for (final x in const [5.0, 12.0, 19.0]) {
    c.drawCircle(Offset(x, 12), 1.6, dot);
  }
}

void _drawShare(Canvas c, Paint p) {
  c.drawLine(const Offset(12, 15), const Offset(12, 4), p);
  c.drawPath(
    Path()
      ..moveTo(7.5, 8.5)
      ..lineTo(12, 4)
      ..lineTo(16.5, 8.5),
    p,
  );
  c.drawPath(
    Path()
      ..moveTo(6, 12)
      ..lineTo(5, 12)
      ..lineTo(5, 20)
      ..lineTo(19, 20)
      ..lineTo(19, 12)
      ..lineTo(18, 12),
    p,
  );
}

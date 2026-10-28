import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import 'selection.dart';
import 'tile.dart';
import 'timeline_model.dart';

/// Bottom bar while selecting: count, Download, Trash, Free up space.
///
/// Each action receives only the selected items it applies to and is
/// disabled when none do (download: not on this phone; trash: has a server
/// copy; free up: on both and backed up).
class SelectionBar extends ConsumerWidget {
  const SelectionBar({super.key, required this.resolve});

  /// Looks the selected keys up in the current data.
  final List<TimelineItem> Function(Set<String> keys) resolve;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final keys = ref.watch(selectionProvider.select((s) => s.keys));
    final items = resolve(keys);
    final actions = ref.read(timelineActionsProvider);
    final controller = ref.read(selectionProvider.notifier);

    Future<void> run(
      Future<void> Function(List<TimelineItem>) act,
      List<TimelineItem> eligible,
    ) async {
      await act(eligible);
      controller.exit();
    }

    final dl = downloadable(items);
    final tr = trashable(items);
    final fr = freeable(items);
    return DecoratedBox(
      key: const Key('selectionBar'),
      decoration: const BoxDecoration(
        color: Tokens.navBackground,
        border: Border(top: BorderSide(color: Tokens.navBorder)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              Semantics(
                button: true,
                label: 'Cancel selection',
                excludeSemantics: true,
                child: InkResponse(
                  onTap: controller.exit,
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(child: StrokeIcon(drawCloseIcon)),
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  keys.isEmpty ? 'Select items' : '${keys.length} selected',
                  key: const Key('selectionCount'),
                  style: bodyStyle(size: 15, weight: 600),
                ),
              ),
              _Action(
                label: 'Download',
                draw: drawDownloadIcon,
                enabled: dl.isNotEmpty,
                onTap: () => run(actions.download, dl),
              ),
              _Action(
                label: 'Trash',
                draw: drawTrashIcon,
                enabled: tr.isNotEmpty,
                onTap: () async {
                  final ok = await _confirmTrash(context, tr.length);
                  if (ok) await run(actions.trash, tr);
                },
              ),
              _Action(
                label: 'Free up space',
                draw: drawFreeUpIcon,
                enabled: fr.isNotEmpty,
                onTap: () => run(actions.freeUp, fr),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmTrash(BuildContext context, int n) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Tokens.surface,
        title: Text('Move to trash?', style: displayStyle(size: 20)),
        content: Text(
          n == 1
              ? 'Removes it from your server. A copy on this phone stays.'
              : 'Removes $n items from your server. Copies on this phone stay.',
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
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.draw,
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
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                StrokeIcon(draw, color: color),
                const SizedBox(height: 3),
                Text(
                  label,
                  style: bodyStyle(size: 11, weight: 500, color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

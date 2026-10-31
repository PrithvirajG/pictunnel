import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import '../../core/engine/error_copy.dart';
import '../backup/backup_providers.dart';
import '../backup/format.dart';

/// What "Free up space" would remove: phone items already backed up.
class FreeableSummary {
  const FreeableSummary(this.count, this.bytes);
  final int count;
  final int bytes;
}

/// Counts backed-up phone items by walking the phone index. The engine makes
/// the final call (fingerprint and server re-check, P§7.8), so this is what
/// the person is asked about, not a promise.
final freeableSummaryProvider = FutureProvider.autoDispose<FreeableSummary>((
  ref,
) async {
  final engine = ref.watch(engineProvider);
  var count = 0, sum = 0;
  String? after;
  do {
    final page = await engine.listPhoneItems(
      PageRequest(afterKey: after, limit: 500),
    );
    for (final p in page.items) {
      if (p.state == ItemState.backedUp) {
        count++;
        sum += p.size;
      }
    }
    after = page.items.isEmpty ? null : page.nextKey;
  } while (after != null);
  final status = ref.read(backupStatusProvider).value;
  final bytes = (status?.freeableBytes ?? 0) > 0 ? status!.freeableBytes : sum;
  return FreeableSummary(count, bytes);
});

Future<void> showFreeUpSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  backgroundColor: Tokens.surface,
  isScrollControlled: true,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
  ),
  builder: (_) => const FreeUpSheet(),
);

enum _Phase { confirm, working, done, failed }

/// Bottom sheet: how much would be freed, the engine run (the OS shows its
/// own delete dialog), then the result with the reasons any item was kept.
class FreeUpSheet extends ConsumerStatefulWidget {
  const FreeUpSheet({super.key});

  @override
  ConsumerState<FreeUpSheet> createState() => _FreeUpSheetState();
}

class _FreeUpSheetState extends ConsumerState<FreeUpSheet> {
  _Phase _phase = _Phase.confirm;
  FreeUpResult? _result;
  String? _error;

  Future<void> _run() async {
    setState(() => _phase = _Phase.working);
    try {
      final r = await ref.read(engineProvider).freeUpSpace(null);
      if (!mounted) return;
      setState(() {
        _result = r;
        _phase = _Phase.done;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = engineErrorMessage(e);
        _phase = _Phase.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: switch (_phase) {
            _Phase.confirm => _confirm(),
            _Phase.working => _working(),
            _Phase.done => _done(_result!),
            _Phase.failed => _failed(_error!),
          },
        ),
      ),
    );
  }

  List<Widget> _confirm() {
    final summary = ref.watch(freeableSummaryProvider);
    final s = summary.value;
    if (s == null) {
      return [
        if (summary.hasError)
          Text(
            engineErrorMessage(summary.error!),
            style: bodyStyle(size: 15, color: Tokens.muted),
          )
        else
          const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          ),
      ];
    }
    if (s.count == 0) {
      return [
        Text('Nothing to free up', style: displayStyle(size: 22)),
        const SizedBox(height: 8),
        Text(
          'Photos count once they are safely on your server.',
          style: bodyStyle(size: 15, color: Tokens.muted),
        ),
        const SizedBox(height: 20),
        _secondary('Close', () => Navigator.pop(context)),
      ];
    }
    final items = s.count == 1
        ? '1 photo or video'
        : '${formatCount(s.count)} photos and videos';
    return [
      Text(
        'Free up ${formatBytes(s.bytes)}?',
        key: const Key('freeUpTitle'),
        style: displayStyle(size: 22),
      ),
      const SizedBox(height: 8),
      Text(
        'Removes $items from this phone. They stay safe on your server, and '
        'you can download any of them again.',
        key: const Key('freeUpBody'),
        style: bodyStyle(size: 15).copyWith(height: 1.4),
      ),
      const SizedBox(height: 8),
      Text(
        'PicTunnel checks each one with your server first, then your phone '
        'asks you to confirm.',
        style: bodyStyle(size: 13, color: Tokens.muted),
      ),
      const SizedBox(height: 20),
      _primary('Free up ${formatBytes(s.bytes)}', _run),
      const SizedBox(height: 8),
      _secondary('Not now', () => Navigator.pop(context)),
    ];
  }

  List<Widget> _working() => [
    const SizedBox(
      height: 96,
      child: Center(child: CircularProgressIndicator()),
    ),
    Text(
      'Checking with your server…',
      textAlign: TextAlign.center,
      style: bodyStyle(size: 15, color: Tokens.muted),
    ),
    const SizedBox(height: 16),
  ];

  List<Widget> _done(FreeUpResult r) {
    final groups = <String, int>{};
    for (final k in r.skipped) {
      final label = freeUpSkipReason(k.reason);
      groups[label] = (groups[label] ?? 0) + 1;
    }
    final n = r.freedCount;
    final kept = r.skipped.length;
    return [
      Text(
        n == 0 ? 'Nothing was removed' : 'Freed ${formatBytes(r.freedBytes)}',
        key: const Key('freeUpDoneTitle'),
        style: displayStyle(size: 22),
      ),
      const SizedBox(height: 8),
      if (n > 0)
        Text(
          n == 1
              ? '1 item removed from this phone.'
              : '${formatCount(n)} items removed from this phone.',
          style: bodyStyle(size: 15),
        ),
      if (kept > 0) ...[
        const SizedBox(height: 12),
        Text(
          kept == 1
              ? '1 item stays on this phone:'
              : '${formatCount(kept)} items stay on this phone:',
          style: bodyStyle(size: 15, color: Tokens.muted),
        ),
        const SizedBox(height: 6),
        for (final e in groups.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(child: Text(e.key, style: bodyStyle(size: 15))),
                Text(
                  formatCount(e.value),
                  style: bodyStyle(size: 15, color: Tokens.muted),
                ),
              ],
            ),
          ),
      ],
      const SizedBox(height: 20),
      _primary('Done', () => Navigator.pop(context)),
    ];
  }

  List<Widget> _failed(String message) => [
    Text("Couldn't free up space", style: displayStyle(size: 22)),
    const SizedBox(height: 8),
    Text(
      message,
      key: const Key('freeUpError'),
      style: bodyStyle(size: 15, color: Tokens.muted),
    ),
    const SizedBox(height: 20),
    _primary('Try again', _run),
    const SizedBox(height: 8),
    _secondary('Close', () => Navigator.pop(context)),
  ];

  Widget _primary(String label, VoidCallback onTap) => SizedBox(
    height: 48,
    child: FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: Tokens.accent,
        foregroundColor: Tokens.ground,
        shape: const StadiumBorder(),
        textStyle: bodyStyle(size: 15, weight: 600),
      ),
      onPressed: onTap,
      child: Text(label),
    ),
  );

  Widget _secondary(String label, VoidCallback onTap) => SizedBox(
    height: 48,
    child: TextButton(
      style: TextButton.styleFrom(
        foregroundColor: Tokens.text,
        textStyle: bodyStyle(size: 15, weight: 500),
      ),
      onPressed: onTap,
      child: Text(label),
    ),
  );
}

/// The "Battery optimisation" hint in Settings (spec M§10): Android may delay
/// background backups while the app is battery-optimised, so Settings shows a
/// dismissible card until the app is exempt.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';

/// Whether the app is exempt from battery optimisation, and the system flow
/// that grants it.
abstract interface class BatteryOptimization {
  Future<bool> isExempt();

  /// Opens the system's exemption dialog (or its settings list).
  Future<void> requestExemption();
}

/// Android's `PowerManager` through the app's `pictunnel/battery` channel.
/// Every other platform (and a missing channel) reads as exempt.
class ChannelBatteryOptimization implements BatteryOptimization {
  const ChannelBatteryOptimization();

  static const _channel = MethodChannel('pictunnel/battery');

  @override
  Future<bool> isExempt() async {
    if (defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          true;
    } on MissingPluginException {
      return true;
    } on PlatformException {
      return true;
    }
  }

  @override
  Future<void> requestExemption() =>
      _channel.invokeMethod<void>('requestIgnoreBatteryOptimizations');
}

final batteryOptimizationProvider = Provider<BatteryOptimization>(
  (_) => const ChannelBatteryOptimization(),
);

/// Remembers dismissed hints. The composition root persists it in the app
/// database; this default lasts for the session.
abstract interface class HintStore {
  Future<bool> isDismissed(String hint);
  Future<void> dismiss(String hint);
}

class MemoryHintStore implements HintStore {
  final _dismissed = <String>{};
  @override
  Future<bool> isDismissed(String hint) async => _dismissed.contains(hint);
  @override
  Future<void> dismiss(String hint) async => _dismissed.add(hint);
}

final hintStoreProvider = Provider<HintStore>((_) => MemoryHintStore());

const batteryHint = 'battery_optimisation';

/// Whether the card shows: not dismissed, and the app is not exempt.
final batteryHintVisibleProvider = FutureProvider.autoDispose<bool>((
  ref,
) async {
  if (await ref.watch(hintStoreProvider).isDismissed(batteryHint)) {
    return false;
  }
  return !await ref.watch(batteryOptimizationProvider).isExempt();
});

const batteryHintCopy =
    'Android may hold back backups while PicTunnel is battery-optimised. '
    'Let it run in the background so new photos back up on time.';

/// The card; re-checks when the app comes back from the system screen.
class BatteryHintCard extends ConsumerStatefulWidget {
  const BatteryHintCard({super.key});

  @override
  ConsumerState<BatteryHintCard> createState() => _BatteryHintCardState();
}

class _BatteryHintCardState extends ConsumerState<BatteryHintCard> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.invalidate(batteryHintVisibleProvider),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _allow() async {
    try {
      await ref.read(batteryOptimizationProvider).requestExemption();
    } catch (_) {
      // nothing opened; the card stays
    }
    ref.invalidate(batteryHintVisibleProvider);
  }

  Future<void> _dismiss() async {
    await ref.read(hintStoreProvider).dismiss(batteryHint);
    ref.invalidate(batteryHintVisibleProvider);
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(batteryHintVisibleProvider).value != true) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Container(
        key: const Key('batteryHint'),
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
        decoration: BoxDecoration(
          color: Tokens.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Tokens.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Battery optimisation',
              style: bodyStyle(size: 15, weight: 600),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                batteryHintCopy,
                style: bodyStyle(size: 13, color: Tokens.muted),
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  key: const Key('batteryHintDismiss'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    foregroundColor: Tokens.muted,
                  ),
                  onPressed: _dismiss,
                  child: Text(
                    'Not now',
                    style: bodyStyle(size: 14, color: Tokens.muted),
                  ),
                ),
                TextButton(
                  key: const Key('batteryHintAllow'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    foregroundColor: Tokens.accent,
                  ),
                  onPressed: _allow,
                  child: Text(
                    'Allow in background',
                    style: bodyStyle(
                      size: 14,
                      weight: 700,
                      color: Tokens.accent,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

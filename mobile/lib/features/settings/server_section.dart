import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import '../../core/engine/error_copy.dart';
import '../backup/backup_providers.dart';
import '../pairing/pairing_controller.dart';
import 'settings_screen.dart';

/// Clears what the app keeps about the paired server (mirror, sync cursor,
/// cached thumbnails). Overridden by the composition root; a no-op default.
final localDataWiperProvider = Provider<Future<void> Function()>(
  (_) => () async {},
);

/// Unpairs: the engine revokes locally, logs out best-effort and wipes its
/// credentials and DB (M§3); then the local mirror goes, and the router
/// returns to pairing.
final unpairActionProvider = Provider<Future<void> Function()>(
  (ref) => () async {
    await ref.read(engineProvider).unpair();
    await ref.read(localDataWiperProvider)();
    ref.invalidate(serverConnectedProvider);
  },
);

/// "Connected · LAN" / "Connected · Remote" / "Not connected".
String connectionLabel(ServerConnection? c) {
  if (c == null) return 'Not connected';
  return c.onLan ? 'Connected · LAN' : 'Connected · Remote';
}

class ServerSection extends ConsumerWidget {
  const ServerSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(serverInfoProvider);
    final c = info.value;
    return SettingsSection(
      title: 'Server',
      child: SettingsCard(
        children: [
          SettingsValueRow(
            key: const Key('serverRow'),
            label: c?.name ?? 'Server',
            value: info.isLoading ? '' : connectionLabel(c),
            valueColor: c == null ? Tokens.muted : Tokens.ok,
          ),
          SettingsValueRow(
            label: 'This phone',
            value: ref.watch(deviceNameProvider),
          ),
          SettingsActionRow(
            key: const Key('pairAgain'),
            label: 'Pair again',
            onTap: () => _confirmAndUnpair(
              context,
              ref,
              title: 'Pair again?',
              body:
                  'This phone forgets the server, then you scan a new code. '
                  'Photos already backed up stay on your server.',
              action: 'Pair again',
            ),
          ),
          SettingsActionRow(
            key: const Key('unpair'),
            label: 'Unpair this phone',
            color: Tokens.text,
            onTap: () => _confirmAndUnpair(
              context,
              ref,
              title: 'Unpair this phone?',
              body:
                  'Backup stops and this phone forgets the server. Photos on '
                  'your server stay there, and nothing is deleted from this '
                  'phone.',
              action: 'Unpair',
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _confirmAndUnpair(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String body,
  required String action,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final ok = await showDialog<bool>(
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
          key: const Key('confirmUnpair'),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(unpairActionProvider)();
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(engineErrorMessage(e))));
  }
}

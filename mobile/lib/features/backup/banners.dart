import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import '../../core/engine/error_copy.dart';
import '../settings/server_section.dart' show unpairActionProvider;
import 'backup_providers.dart';

/// Banner copy keyed by `PauseReason.name` (spec M§8). Adding a reason is one
/// line.
const pauseReasonCopy = <String, String>{
  'user': 'Backup is paused.',
  'wifiRequired': 'Waiting for Wi-Fi. Backup resumes when you connect.',
  'chargingRequired':
      'Waiting for your charger. Backup resumes when you plug in.',
  'serverFull': 'Your server is out of space. Backup is paused.',
  'quota': 'Your storage limit on the server is reached. Backup is paused.',
  'clientTooOld':
      'This version of PicTunnel is too old for your server. Update the app to continue.',
  'permission':
      "PicTunnel can't read your photos. Allow photo access to back up.",
  'serverCertificateChanged':
      "Your server's security certificate changed. Pair again to continue.",
};

const partialAccessCopy =
    'PicTunnel can only see the photos you selected. Allow full access to back up everything.';

enum BannerAction { resume, allowFullAccess, pairAgain, none }

class BannerSpec {
  const BannerSpec(this.message, this.action, this.actionLabel);
  final String message;
  final BannerAction action;
  final String? actionLabel;
}

/// What banner (if any) the Backup screen shows for [status] and [access].
/// A pause reason wins over partial access.
BannerSpec? bannerFor(BackupStatus status, MediaAccess access) {
  final reason = status.pauseReason;
  if (status.paused || reason != null) {
    final key = reason?.name ?? 'user';
    final message = pauseReasonCopy[key] ?? pauseReasonCopy['user']!;
    return switch (key) {
      'user' => BannerSpec(message, BannerAction.resume, 'Resume'),
      'permission' => BannerSpec(
        message,
        BannerAction.allowFullAccess,
        'Allow access',
      ),
      'serverCertificateChanged' => BannerSpec(
        message,
        BannerAction.pairAgain,
        'Pair again',
      ),
      _ => BannerSpec(message, BannerAction.none, null),
    };
  }
  return switch (access) {
    MediaAccess.none => BannerSpec(
      pauseReasonCopy['permission']!,
      BannerAction.allowFullAccess,
      'Allow access',
    ),
    MediaAccess.partial => const BannerSpec(
      partialAccessCopy,
      BannerAction.allowFullAccess,
      'Allow full access',
    ),
    MediaAccess.full => null,
  };
}

class StatusBanner extends ConsumerWidget {
  const StatusBanner({super.key, required this.spec});

  final BannerSpec spec;

  Future<void> _act(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      switch (spec.action) {
        case BannerAction.resume:
          await ref.read(engineProvider).runNow();
        case BannerAction.allowFullAccess:
          await ref.read(requestFullAccessProvider)();
        case BannerAction.pairAgain:
          // The same unpair as Settings: engine, local mirror, then pairing.
          await ref.read(unpairActionProvider)();
        case BannerAction.none:
          break;
      }
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(engineErrorMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      key: const Key('statusBanner'),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2214),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF4A3A1A)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                spec.message,
                style: bodyStyle(size: 14, weight: 500),
              ),
            ),
          ),
          if (spec.actionLabel != null) ...[
            const SizedBox(width: 8),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: Tokens.accent,
              ),
              onPressed: () => _act(context, ref),
              child: Text(
                spec.actionLabel!,
                style: bodyStyle(size: 14, weight: 700, color: Tokens.accent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

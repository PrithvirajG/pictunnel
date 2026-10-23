import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import 'backup_providers.dart';
import 'banners.dart';
import 'format.dart';
import 'progress_ring.dart';
import 'queue_list.dart';
import 'rule_chips.dart';
import 'upload_card.dart';

class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(backupStatusProvider).value;
    final access = ref.watch(mediaAccessProvider);
    return SafeArea(
      child: status == null
          ? const SizedBox.shrink()
          : _Body(status: status, access: access),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.status, required this.access});

  final BackupStatus status;
  final MediaAccess access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = bannerFor(status, access);
    final upload = status.uploading;
    final settings = ref.watch(engineSettingsProvider).value;
    final queue = ref.watch(upNextProvider).value ?? const <PhoneItem>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      children: [
        const _Header(),
        const SizedBox(height: 20),
        _StatusRow(status: status),
        if (banner != null) ...[
          const SizedBox(height: 16),
          StatusBanner(spec: banner),
        ],
        if (upload != null && !status.paused) ...[
          const SizedBox(height: 20),
          UploadCard(upload: upload),
        ],
        const SizedBox(height: 20),
        QueueList(items: queue, waitingNote: _waitingNote(status)),
        if (settings != null) ...[
          const SizedBox(height: 20),
          RuleChips(settings: settings),
        ],
        const SizedBox(height: 12),
        if (status.needsAttention > 0)
          _EntryTile(
            key: const Key('attentionEntry'),
            label: 'Needs attention (${status.needsAttention})',
            onTap: () => context.push('/backup/attention'),
          ),
        _EntryTile(
          key: const Key('activityEntry'),
          label: 'Activity',
          onTap: () => context.push('/backup/activity'),
        ),
      ],
    );
  }
}

String _waitingNote(BackupStatus s) => switch (s.pauseReason) {
  PauseReason.wifiRequired => 'Waiting for Wi-Fi',
  PauseReason.chargingRequired => 'Waiting for charger',
  _ => s.paused ? 'Paused' : 'Waiting',
};

class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(serverInfoProvider).value;
    final label = info == null
        ? 'Not connected'
        : '${info.name} · ${info.onLan ? 'Wi-Fi' : 'Remote'}';
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text('PicTunnel', style: displayStyle(size: 20)),
        Flexible(
          child: Container(
            key: const Key('serverChip'),
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Tokens.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF2E2E2E)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: info == null ? Tokens.muted : Tokens.ok,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: bodyStyle(size: 13, weight: 500),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.status});

  final BackupStatus status;

  String get _summary {
    if (status.preparing > 0) {
      final done = (status.total - status.preparing).clamp(0, status.total);
      return 'Preparing ${formatCount(done)} of ${formatCount(status.total)}';
    }
    final up = status.uploading;
    final left = status.queued > 0 ? status.queued : (up != null ? 1 : 0);
    if (status.paused) {
      return left > 0 ? 'Paused · ${formatCount(left)} left' : 'Paused';
    }
    if (left == 0) return 'All backed up';
    final bytesLeft = up == null
        ? 0
        : (left - 1) * up.totalBytes + (up.totalBytes - up.sentBytes);
    final eta = up == null ? null : formatEta(bytesLeft, up.bytesPerSecond);
    return eta == null
        ? '${formatCount(left)} left'
        : '${formatCount(left)} left · $eta';
  }

  @override
  Widget build(BuildContext context) {
    final fraction = status.total > 0 ? status.backedUp / status.total : 0.0;
    return Row(
      children: [
        ProgressRing(fraction: fraction),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                formatCount(status.backedUp),
                key: const Key('backedUpCount'),
                style: displayStyle(
                  size: 34,
                ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              Text(
                'photos and videos backed up',
                style: bodyStyle(size: 15, color: const Color(0xFFC9C4BB)),
              ),
              const SizedBox(height: 4),
              Text(
                _summary,
                key: const Key('statusSummary'),
                style: bodyStyle(size: 14, weight: 600, color: Tokens.accent),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 56,
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFF222222))),
        ),
        child: Row(
          children: [
            Expanded(child: Text(label, style: bodyStyle(size: 15))),
            Text('›', style: bodyStyle(size: 24, color: Tokens.muted)),
          ],
        ),
      ),
    );
  }
}

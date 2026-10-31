import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import '../../core/engine/error_copy.dart';
import '../backup/backup_providers.dart';
import '../backup/format.dart';
import 'free_up_sheet.dart';
import 'server_section.dart';

/// Returns a copy of [s] with the given fields replaced.
EngineSettings copySettings(
  EngineSettings s, {
  bool? wifiOnly,
  bool? chargingOnly,
  bool? includeVideos,
  bool? keepUneditedOriginals,
  bool? allAlbums,
  List<String>? albumIds,
}) => EngineSettings(
  wifiOnly: wifiOnly ?? s.wifiOnly,
  chargingOnly: chargingOnly ?? s.chargingOnly,
  includeVideos: includeVideos ?? s.includeVideos,
  keepUneditedOriginals: keepUneditedOriginals ?? s.keepUneditedOriginals,
  allAlbums: allAlbums ?? s.allAlbums,
  albumIds: albumIds ?? List.of(s.albumIds),
);

/// The engine's backup settings. Changes apply optimistically and roll back
/// when `setSettings` fails.
class SettingsController extends AsyncNotifier<EngineSettings> {
  @override
  Future<EngineSettings> build() => ref.watch(engineProvider).getSettings();

  Future<void> change(EngineSettings next) async {
    final previous = state.value;
    state = AsyncData(next);
    try {
      await ref.read(engineProvider).setSettings(next);
      ref.invalidate(engineSettingsProvider);
    } catch (_) {
      if (previous != null && ref.mounted) state = AsyncData(previous);
      rethrow;
    }
  }
}

final settingsControllerProvider =
    AsyncNotifierProvider.autoDispose<SettingsController, EngineSettings>(
      SettingsController.new,
    );

/// "Also keep unedited originals" only exists on iOS (spec H3); Android
/// edits replace the file.
bool get showsUneditedOriginals => defaultTargetPlatform == TargetPlatform.iOS;

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Text('Settings', style: displayStyle()),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _BackupSection(),
                SizedBox(height: 20),
                _StorageSection(),
                SizedBox(height: 20),
                ServerSection(),
                SizedBox(height: 20),
                _MoreSection(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _apply(
  BuildContext context,
  WidgetRef ref,
  EngineSettings next,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref.read(settingsControllerProvider.notifier).change(next);
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text(engineErrorMessage(e))),
    );
  }
}

class _BackupSection extends ConsumerWidget {
  const _BackupSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsControllerProvider).value;
    final rows = <Widget>[];
    if (s != null) {
      rows.addAll([
        SettingsToggle(
          label: 'Use mobile data',
          hint: 'Off: waits for Wi-Fi',
          value: !s.wifiOnly,
          onChanged: (v) => _apply(context, ref, copySettings(s, wifiOnly: !v)),
        ),
        SettingsToggle(
          label: 'Only while charging',
          hint: 'Saves battery on big backups',
          value: s.chargingOnly,
          onChanged: (v) =>
              _apply(context, ref, copySettings(s, chargingOnly: v)),
        ),
        SettingsToggle(
          label: 'Include videos',
          hint: 'Videos can be large',
          value: s.includeVideos,
          onChanged: (v) =>
              _apply(context, ref, copySettings(s, includeVideos: v)),
        ),
        if (showsUneditedOriginals)
          SettingsToggle(
            label: 'Also keep unedited originals',
            hint: 'iPhone edits are backed up either way',
            value: s.keepUneditedOriginals,
            onChanged: (v) =>
                _apply(context, ref, copySettings(s, keepUneditedOriginals: v)),
          ),
        SettingsNavRow(
          key: const Key('albumsRow'),
          label: 'Albums',
          hint: albumsSummary(s),
          onTap: () => context.push('/settings/albums'),
        ),
      ]);
    }
    return SettingsSection(
      title: 'Backup',
      child: SettingsCard(children: rows),
    );
  }
}

String albumsSummary(EngineSettings s) {
  if (s.allAlbums) return 'All albums';
  final n = s.albumIds.length;
  if (n == 0) return 'No albums chosen';
  return n == 1 ? '1 album' : '$n albums';
}

class _StorageSection extends ConsumerWidget {
  const _StorageSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(
      backupStatusProvider.select((s) => s.value?.freeableBytes ?? 0),
    );
    return SettingsSection(
      title: 'Phone storage',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Tokens.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                bytes > 0
                    ? '${formatBytes(bytes)} of photos on this phone are '
                          'already safe on your server.'
                    : 'Nothing to free up yet. Photos count once they are '
                          'safely on your server.',
                style: bodyStyle(size: 15).copyWith(height: 1.4),
              ),
              if (bytes > 0) ...[
                const SizedBox(height: 12),
                SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    key: const Key('freeUpButton'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Tokens.accent,
                      side: const BorderSide(color: Tokens.accent),
                      shape: const StadiumBorder(),
                      textStyle: bodyStyle(size: 15, weight: 600),
                    ),
                    onPressed: () => showFreeUpSheet(context),
                    child: Text('Free up ${formatBytes(bytes)}'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MoreSection extends StatelessWidget {
  const _MoreSection();

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      title: 'More',
      child: SettingsCard(
        children: [
          SettingsNavRow(
            label: 'Trash',
            hint: 'Items you moved to trash on your server',
            onTap: () => context.push('/settings/trash'),
          ),
          SettingsNavRow(
            label: 'About',
            hint: 'Versions and licenses',
            onTap: () => context.push('/settings/about'),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ building blocks

/// Row separator inside a settings card (canvas `#262626`).
const settingsDivider = Color(0xFF262626);

/// Uppercase muted title above a card.
class SettingsSection extends StatelessWidget {
  const SettingsSection({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Semantics(
            header: true,
            child: Text(
              title.toUpperCase(),
              style: bodyStyle(
                size: 13,
                weight: 600,
                color: Tokens.muted,
              ).copyWith(letterSpacing: 0.78),
            ),
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// Rounded surface holding rows separated by hairlines.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: Tokens.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, c) in children.indexed)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: i == children.length - 1
                      ? null
                      : const Border(
                          bottom: BorderSide(color: settingsDivider),
                        ),
                ),
                child: c,
              ),
          ],
        ),
      ),
    );
  }
}

class _LabelBlock extends StatelessWidget {
  const _LabelBlock({required this.label, this.hint});

  final String label;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: bodyStyle(size: 15)),
        if (hint != null) ...[
          const SizedBox(height: 2),
          Text(hint!, style: bodyStyle(size: 12, color: Tokens.muted)),
        ],
      ],
    );
  }
}

/// A labelled switch row, at least 56 dp tall.
class SettingsToggle extends StatelessWidget {
  const SettingsToggle({
    super.key,
    required this.label,
    this.hint,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        child: InkWell(
          onTap: () => onChanged(!value),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Expanded(child: _LabelBlock(label: label, hint: hint)),
                  const SizedBox(width: 12),
                  DarkroomSwitch(value: value),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The canvas switch: 44x26 track, accent when on.
class DarkroomSwitch extends StatelessWidget {
  const DarkroomSwitch({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: 44,
      height: 26,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: value ? Tokens.accent : const Color(0xFF3A3A3A),
        borderRadius: BorderRadius.circular(13),
      ),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: 20,
        height: 20,
        decoration: const BoxDecoration(
          color: Tokens.text,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// A row that opens another screen.
class SettingsNavRow extends StatelessWidget {
  const SettingsNavRow({
    super.key,
    required this.label,
    this.hint,
    this.trailing,
    required this.onTap,
  });

  final String label;
  final String? hint;
  final String? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Expanded(child: _LabelBlock(label: label, hint: hint)),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: bodyStyle(size: 13, color: Tokens.muted),
                  ),
                const SizedBox(width: 8),
                ExcludeSemantics(
                  child: Text(
                    '›',
                    style: bodyStyle(size: 22, color: Tokens.muted),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A label with a value on the right (52 dp), as in the canvas server card.
class SettingsValueRow extends StatelessWidget {
  const SettingsValueRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor = Tokens.muted,
  });

  final String label;
  final String value;
  final Color valueColor;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Expanded(child: Text(label, style: bodyStyle(size: 15))),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  value,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: bodyStyle(size: 13, color: valueColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A plain tappable text row (Pair again, Unpair).
class SettingsActionRow extends StatelessWidget {
  const SettingsActionRow({
    super.key,
    required this.label,
    required this.onTap,
    this.color = Tokens.accent,
  });

  final String label;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(label, style: bodyStyle(size: 15, color: color)),
            ),
          ),
        ),
      ),
    );
  }
}

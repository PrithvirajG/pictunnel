import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/theme/typography.dart';
import '../../core/engine/engine.dart';
import '../../core/engine/error_copy.dart';
import '../backup/format.dart';
import 'settings_screen.dart';

final albumsProvider = FutureProvider.autoDispose<List<AlbumInfo>>(
  (ref) => ref.watch(engineProvider).listAlbums(),
);

/// Chooses which albums are backed up: every album, or a selection.
class AlbumPickerScreen extends ConsumerWidget {
  const AlbumPickerScreen({super.key});

  Future<void> _apply(
    BuildContext context,
    WidgetRef ref,
    EngineSettings next,
  ) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref.read(settingsControllerProvider.notifier).change(next);
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(engineErrorMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsControllerProvider).value;
    final albums = ref.watch(albumsProvider);
    return Scaffold(
      appBar: AppBar(title: Text('Albums', style: displayStyle(size: 20))),
      body: s == null
          ? const SizedBox.shrink()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                SettingsCard(
                  children: [
                    SettingsToggle(
                      key: const Key('allAlbums'),
                      label: 'All albums',
                      hint: 'Back up everything on this phone',
                      value: s.allAlbums,
                      onChanged: (v) =>
                          _apply(context, ref, copySettings(s, allAlbums: v)),
                    ),
                  ],
                ),
                if (!s.allAlbums) ...[
                  const SizedBox(height: 20),
                  SettingsSection(
                    title: 'Back up these albums',
                    child: albums.when(
                      loading: () => const SizedBox(height: 56),
                      error: (e, _) => Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          engineErrorMessage(e),
                          style: bodyStyle(size: 15, color: Tokens.muted),
                        ),
                      ),
                      data: (list) => list.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(14),
                              child: Text(
                                'No albums on this phone.',
                                style: bodyStyle(size: 15, color: Tokens.muted),
                              ),
                            )
                          : SettingsCard(
                              children: [
                                for (final a in list)
                                  _AlbumRow(
                                    album: a,
                                    selected: s.albumIds.contains(a.id),
                                    onChanged: (on) => _apply(
                                      context,
                                      ref,
                                      copySettings(
                                        s,
                                        albumIds: on
                                            ? [...s.albumIds, a.id]
                                            : [
                                                for (final id in s.albumIds)
                                                  if (id != a.id) id,
                                              ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                  if (s.albumIds.isEmpty) ...[
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        'Choose at least one album, or nothing is backed up.',
                        key: const Key('noAlbumsHint'),
                        style: bodyStyle(size: 13, color: Tokens.accent),
                      ),
                    ),
                  ],
                ],
              ],
            ),
    );
  }
}

class _AlbumRow extends StatelessWidget {
  const _AlbumRow({
    required this.album,
    required this.selected,
    required this.onChanged,
  });

  final AlbumInfo album;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final n = album.count;
    return MergeSemantics(
      child: Semantics(
        checked: selected,
        child: InkWell(
          onTap: () => onChanged(!selected),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(album.name, style: bodyStyle(size: 15)),
                        const SizedBox(height: 2),
                        Text(
                          n == 1 ? '1 item' : '${formatCount(n)} items',
                          style: bodyStyle(size: 12, color: Tokens.muted),
                        ),
                      ],
                    ),
                  ),
                  _Check(selected: selected),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? Tokens.accent : Colors.transparent,
        border: Border.all(
          color: selected ? Tokens.accent : Tokens.muted,
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child: selected
          ? Text(
              '✓',
              style: bodyStyle(size: 14, weight: 700, color: Tokens.ground),
            )
          : null,
    );
  }
}

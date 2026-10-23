import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';

/// Seeds from `getStatus()` then follows `status$`.
final backupStatusProvider = StreamProvider.autoDispose<BackupStatus>((
  ref,
) async* {
  final engine = ref.watch(engineProvider);
  yield await engine.getStatus();
  yield* engine.status$;
});

final serverInfoProvider = FutureProvider.autoDispose<ServerConnection?>(
  (ref) => ref.watch(engineProvider).serverInfo(),
);

final engineSettingsProvider = FutureProvider.autoDispose<EngineSettings>(
  (ref) => ref.watch(engineProvider).getSettings(),
);

/// Queued items, refetched when the queue length changes.
final upNextProvider = FutureProvider.autoDispose<List<PhoneItem>>((ref) async {
  ref.watch(backupStatusProvider.select((s) => s.value?.queued));
  final page = await ref
      .watch(engineProvider)
      .listPhoneItems(PageRequest(limit: 200));
  return page.items.where((i) => i.state == ItemState.queued).take(5).toList();
});

final attentionProvider = FutureProvider.autoDispose<List<AttentionItem>>(
  (ref) => ref.watch(engineProvider).listAttention(),
);

final activityProvider = FutureProvider.autoDispose<List<ActivityEntry>>(
  (ref) => ref.watch(engineProvider).listActivity(200),
);

final phoneThumbProvider = FutureProvider.autoDispose.family<Uint8List, String>(
  (ref, localId) => ref.watch(engineProvider).phoneThumbnail(localId, 96),
);

/// How much of the photo library the OS lets the app read. The engine only
/// reports a `permission` pause; partial access (Android 14+ selected photos,
/// iOS limited) is supplied by the platform layer through this provider.
enum MediaAccess { full, partial, denied }

final mediaAccessProvider = Provider<MediaAccess>((_) => MediaAccess.full);

/// Opens the OS flow for granting full access. Overridden by the platform
/// layer; does nothing until then.
final requestFullAccessProvider = Provider<Future<void> Function()>(
  (_) => () async {},
);

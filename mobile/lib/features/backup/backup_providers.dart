import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/engine/engine.dart';

/// Seeds from `getStatus()` then follows `status$`. A failing seed or a
/// failing event is reported as that emission's error; the provider keeps
/// following `status$` either way, and a live status is never replaced by a
/// seed that answered late.
final backupStatusProvider = StreamProvider.autoDispose<BackupStatus>((ref) {
  final engine = ref.watch(engineProvider);
  final out = StreamController<BackupStatus>();
  var live = false;
  final sub = engine.status$.listen(
    (s) {
      live = true;
      out.add(s);
    },
    onError: (Object e, StackTrace st) {
      if (!out.isClosed) out.addError(e, st);
    },
  );
  ref.onDispose(() {
    sub.cancel();
    out.close();
  });
  Future<BackupStatus>.sync(engine.getStatus).then(
    (s) {
      if (!live && !out.isClosed) out.add(s);
    },
    onError: (Object e, StackTrace st) {
      if (!live && !out.isClosed) out.addError(e, st);
    },
  );
  return out.stream;
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

/// How much of the photo library the OS lets the app read (Android 14+
/// selected photos, iOS limited), as the engine reports it in
/// [BackupStatus.mediaAccess]. Full until the first status arrives.
final mediaAccessProvider = Provider.autoDispose<MediaAccess>(
  (ref) =>
      ref.watch(backupStatusProvider.select((s) => s.value?.mediaAccess)) ??
      MediaAccess.full,
);

/// "Allow full access": the engine runs the OS permission flow (Android's
/// permission dialog, iOS's photo access prompt) or opens the app's settings
/// page when only the user can change it there. The status is re-read right
/// away, and again when the app comes back to the foreground (from Settings).
final requestFullAccessProvider = Provider<Future<MediaAccess> Function()>((
  ref,
) {
  AppLifecycleListener? onResume;
  void refresh() => ref.invalidate(backupStatusProvider);
  ref.onDispose(() => onResume?.dispose());
  return () async {
    final access = await ref.read(engineProvider).requestMediaAccess();
    refresh();
    onResume?.dispose();
    onResume = null;
    if (access != MediaAccess.full) {
      onResume = AppLifecycleListener(
        onResume: () {
          onResume?.dispose();
          onResume = null;
          refresh();
        },
      );
    }
    return access;
  };
});

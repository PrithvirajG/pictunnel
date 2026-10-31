import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/app/theme/theme.dart';
import 'package:pictunnel/core/engine/engine.dart';
import 'package:pictunnel/core/engine/pigeon.g.dart' show EngineHostApi;
import 'package:pictunnel/features/backup/backup_providers.dart';
import 'package:pictunnel/features/backup/banners.dart';

/// The Pigeon host with the OS permission flow faked: [grant] is what the
/// user allows when asked; [error] makes the request fail.
class _AccessHost extends EngineHostApi {
  _AccessHost(this.access);

  MediaAccess access;
  MediaAccess grant = MediaAccess.full;
  PlatformException? error;
  var requests = 0;
  var statusReads = 0;

  @override
  Future<BackupStatus> getStatus() async {
    statusReads++;
    return BackupStatus(
      backedUp: 0,
      total: 10,
      queued: 0,
      needsAttention: 0,
      skipped: 0,
      freeableBytes: 0,
      paused: false,
      preparing: 0,
      mediaAccess: access,
    );
  }

  @override
  Future<MediaAccess> requestMediaAccess() async {
    requests++;
    final e = error;
    if (e != null) throw e;
    return access = grant;
  }
}

/// The banner exactly as the Backup screen derives it, from the real
/// providers over the engine.
class _Banner extends ConsumerWidget {
  const _Banner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(backupStatusProvider).value;
    if (status == null) return const SizedBox();
    final spec = bannerFor(status, ref.watch(mediaAccessProvider));
    return spec == null ? const Text('no banner') : StatusBanner(spec: spec);
  }
}

Future<_AccessHost> _pump(WidgetTester t, MediaAccess access) async {
  final host = _AccessHost(access);
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        engineProvider.overrideWithValue(
          PigeonEngine(host: host, registerEvents: false),
        ),
      ],
      child: MaterialApp(
        theme: darkroomTheme(),
        home: const Scaffold(body: Center(child: _Banner())),
      ),
    ),
  );
  await t.pumpAndSettle();
  return host;
}

Future<void> _backToForeground(WidgetTester t) async {
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    t.binding.handleAppLifecycleStateChanged(s);
  }
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Allow full access asks the engine and the banner goes away', (
    t,
  ) async {
    final host = await _pump(t, MediaAccess.partial);
    expect(find.text(partialAccessCopy), findsOneWidget);

    await t.tap(find.text('Allow full access'));
    await t.pumpAndSettle();

    expect(host.requests, 1);
    expect(find.text(partialAccessCopy), findsNothing);
    expect(find.text('no banner'), findsOneWidget);
  });

  testWidgets('no access: Allow access asks too', (t) async {
    final host = await _pump(t, MediaAccess.none);
    host.grant = MediaAccess.partial;
    await t.tap(find.text('Allow access'));
    await t.pumpAndSettle();
    expect(host.requests, 1);
    expect(find.text(partialAccessCopy), findsOneWidget);
  });

  testWidgets('access granted in Settings shows once the app is back', (
    t,
  ) async {
    final host = await _pump(t, MediaAccess.partial);
    // The engine opened Settings: nothing changed yet.
    host.grant = MediaAccess.partial;
    await t.tap(find.text('Allow full access'));
    await t.pumpAndSettle();
    expect(find.text(partialAccessCopy), findsOneWidget);

    // The user allows full access in Settings and comes back.
    host.access = MediaAccess.full;
    final reads = host.statusReads;
    await _backToForeground(t);
    expect(host.statusReads, greaterThan(reads));
    expect(find.text('no banner'), findsOneWidget);
  });

  testWidgets('a failed request explains itself', (t) async {
    final host = await _pump(t, MediaAccess.partial);
    host.error = PlatformException(code: 'no_activity');
    await t.tap(find.text('Allow full access'));
    await t.pumpAndSettle();
    expect(host.requests, 1);
    expect(find.text('Open PicTunnel and try again.'), findsOneWidget);
    expect(find.text(partialAccessCopy), findsOneWidget);
  });
}

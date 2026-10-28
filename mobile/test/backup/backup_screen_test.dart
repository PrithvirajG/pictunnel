import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pictunnel/app/theme/theme.dart';
import 'package:pictunnel/core/engine/engine.dart';
import 'package:pictunnel/core/engine/fake_engine.dart';
import 'package:pictunnel/features/activity/activity_screen.dart';
import 'package:pictunnel/features/attention/attention_screen.dart';
import 'package:pictunnel/features/backup/backup_providers.dart';
import 'package:pictunnel/features/backup/backup_screen.dart';
import 'package:pictunnel/features/backup/banners.dart';

BackupStatus status({
  int backedUp = 12482,
  int total = 12490,
  int queued = 0,
  UploadProgress? uploading,
  int needsAttention = 0,
  bool paused = false,
  PauseReason? reason,
  int preparing = 0,
  MediaAccess access = MediaAccess.full,
}) => BackupStatus(
  backedUp: backedUp,
  total: total,
  queued: queued,
  uploading: uploading,
  needsAttention: needsAttention,
  skipped: 0,
  freeableBytes: 0,
  paused: paused,
  pauseReason: reason,
  preparing: preparing,
  mediaAccess: access,
);

UploadProgress upload() => UploadProgress(
  localId: 'a',
  filename: 'IMG_4521.HEIC',
  sentBytes: 2097152,
  totalBytes: 3355443,
  bytesPerSecond: 1468006.0,
);

PhoneItem queuedItem(int i) => PhoneItem(
  localId: 'q$i',
  filename: 'IMG_000$i.HEIC',
  takenAtMs: DateTime(2026, 10, 3, 14, i).millisecondsSinceEpoch,
  mime: i.isEven ? 'image/heic' : 'video/mp4',
  size: 1000,
  state: ItemState.queued,
  isLivePhoto: false,
);

FakeEngine engineWith(BackupStatus s) {
  final e = FakeEngine(
    connection: ServerConnection(
      serverId: 's',
      name: 'Home server',
      activeEndpoint: 'https://x',
      onLan: true,
      fp16: 'AB',
    ),
  );
  e.status = s;
  e.phoneItems = [for (var i = 0; i < 3; i++) queuedItem(i)];
  return e;
}

Future<void> pumpBackup(
  WidgetTester t,
  FakeEngine e, {
  MediaAccess access = MediaAccess.full,
}) async {
  t.view.physicalSize = const Size(390 * 2, 844 * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: BackupScreen()),
      ),
      GoRoute(
        path: '/backup/attention',
        builder: (_, _) => const AttentionScreen(),
      ),
      GoRoute(
        path: '/backup/activity',
        builder: (_, _) => const ActivityScreen(),
      ),
    ],
  );
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        engineProvider.overrideWithValue(e),
        mediaAccessProvider.overrideWithValue(access),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: darkroomTheme(),
        routerConfig: router,
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('idle shows all backed up and no card or banner', (t) async {
    await pumpBackup(t, engineWith(status(total: 12482)));
    expect(find.text('12,482'), findsOneWidget);
    expect(find.text('photos and videos backed up'), findsOneWidget);
    expect(find.text('All backed up'), findsOneWidget);
    expect(find.byKey(const Key('uploadCard')), findsNothing);
    expect(find.byKey(const Key('statusBanner')), findsNothing);
    expect(find.byKey(const Key('attentionEntry')), findsNothing);
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Home server · Wi-Fi'), findsOneWidget);
  });

  testWidgets('uploading shows card, left count and eta', (t) async {
    await pumpBackup(t, engineWith(status(queued: 80, uploading: upload())));
    expect(find.text('Uploading IMG_4521.HEIC'), findsOneWidget);
    expect(find.text('2.0 of 3.2 MB · 1.4 MB/s'), findsOneWidget);
    expect(
      find.text('If the connection drops, it picks up where it left off.'),
      findsOneWidget,
    );
    expect(find.textContaining('80 left · about'), findsOneWidget);
    expect(find.text('UP NEXT'), findsOneWidget);
    expect(find.text('IMG_0000.HEIC'), findsOneWidget);
    expect(find.text('Wi-Fi only'), findsOneWidget);
    expect(find.text('Videos included'), findsOneWidget);
    expect(find.text('Any battery level'), findsOneWidget);
  });

  testWidgets('preparing n of N', (t) async {
    await pumpBackup(t, engineWith(status(total: 5000, preparing: 1200)));
    expect(find.text('Preparing 3,800 of 5,000'), findsOneWidget);
  });

  testWidgets('needs attention entry opens the screen and retries', (t) async {
    final e = engineWith(status(needsAttention: 2));
    e.attention = [
      AttentionItem(
        localId: 'x',
        filename: 'IMG_1.JPG',
        code: 'file_too_large',
        message: 'm',
        attempts: 1,
      ),
      AttentionItem(
        localId: 'y',
        filename: 'IMG_2.JPG',
        code: 'weird_new_code',
        message: 'Server said no',
        attempts: 3,
      ),
    ];
    await pumpBackup(t, e);
    expect(find.text('Needs attention (2)'), findsOneWidget);
    await t.tap(find.text('Needs attention (2)'));
    await t.pumpAndSettle();
    expect(find.text(problemCopy['file_too_large']!), findsOneWidget);
    expect(find.text('Server said no'), findsOneWidget);
    await t.tap(find.text('Retry').first);
    await t.pumpAndSettle();
    expect(e.retryCalls.single, ['x']);
    expect(find.text('IMG_1.JPG'), findsNothing);
  });

  testWidgets('tombstoned item offers back up again', (t) async {
    final e = engineWith(status(needsAttention: 1));
    e.attention = [
      AttentionItem(
        localId: 'z',
        filename: 'IMG_9.JPG',
        code: 'tombstoned',
        message: 'm',
        attempts: 0,
        sha256: 'ab' * 32,
      ),
    ];
    await pumpBackup(t, e);
    await t.tap(find.text('Needs attention (1)'));
    await t.pumpAndSettle();
    expect(find.text('Retry'), findsNothing);
    await t.tap(find.text('Back up again'));
    await t.pumpAndSettle();
    expect(e.undoSkipCalls.single, 'ab' * 32);
    expect(e.retryCalls, isEmpty);
    expect(find.text('IMG_9.JPG'), findsNothing);
  });

  testWidgets('media access comes from the engine status', (t) async {
    final e = engineWith(status(access: MediaAccess.partial));
    t.view.physicalSize = const Size(390 * 2, 844 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ProviderScope(
        overrides: [engineProvider.overrideWithValue(e)],
        child: MaterialApp(
          theme: darkroomTheme(),
          home: const Scaffold(body: BackupScreen()),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text(partialAccessCopy), findsOneWidget);
  });

  testWidgets('activity lists newest first', (t) async {
    final e = engineWith(status());
    e.activity = [
      ActivityEntry(atMs: 1000, kind: 'upload', message: 'older'),
      ActivityEntry(atMs: 9000, kind: 'upload', message: 'newer'),
    ];
    await pumpBackup(t, e);
    await t.tap(find.text('Activity'));
    await t.pumpAndSettle();
    expect(
      t.getTopLeft(find.text('newer')).dy,
      lessThan(t.getTopLeft(find.text('older')).dy),
    );
  });

  for (final reason in PauseReason.values) {
    testWidgets('paused for ${reason.name} shows its banner', (t) async {
      await pumpBackup(
        t,
        engineWith(status(paused: true, reason: reason, queued: 3)),
      );
      expect(find.text(pauseReasonCopy[reason.name]!), findsOneWidget);
      expect(find.byKey(const Key('uploadCard')), findsNothing);
      expect(find.text('Paused · 3 left'), findsOneWidget);
    });
  }

  testWidgets('user pause resume button calls runNow', (t) async {
    final e = engineWith(
      status(paused: true, reason: PauseReason.user, queued: 3),
    );
    await pumpBackup(t, e);
    await t.tap(find.text('Resume'));
    expect(e.runNowCalls, 1);
  });

  group('permissionBannerStates', () {
    test('every pause reason has copy; certificate copy exists', () {
      for (final r in PauseReason.values) {
        expect(pauseReasonCopy.containsKey(r.name), isTrue, reason: r.name);
      }
      expect(
        pauseReasonCopy['serverCertificateChanged'],
        "Your server's security certificate changed. Pair again to continue.",
      );
    });

    test('maps status and access to banners', () {
      expect(bannerFor(status(), MediaAccess.full), isNull);
      expect(
        bannerFor(status(), MediaAccess.partial)!.message,
        partialAccessCopy,
      );
      expect(
        bannerFor(status(), MediaAccess.none)!.message,
        pauseReasonCopy['permission'],
      );
      expect(
        bannerFor(
          status(paused: true, reason: PauseReason.permission),
          MediaAccess.full,
        )!.message,
        pauseReasonCopy['permission'],
      );
      // A pause reason wins over partial access.
      expect(
        bannerFor(
          status(paused: true, reason: PauseReason.wifiRequired),
          MediaAccess.partial,
        )!.message,
        pauseReasonCopy['wifiRequired'],
      );
    });

    testWidgets('partial access banner offers full access', (t) async {
      var asked = 0;
      final e = engineWith(status());
      t.view.physicalSize = const Size(390 * 2, 844 * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            engineProvider.overrideWithValue(e),
            mediaAccessProvider.overrideWithValue(MediaAccess.partial),
            requestFullAccessProvider.overrideWithValue(() async => asked++),
          ],
          child: MaterialApp(
            theme: darkroomTheme(),
            home: const Scaffold(body: BackupScreen()),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text(partialAccessCopy), findsOneWidget);
      await t.tap(find.text('Allow full access'));
      expect(asked, 1);
    });

    testWidgets('no access shows the permission banner', (t) async {
      await pumpBackup(t, engineWith(status()), access: MediaAccess.none);
      expect(find.text(pauseReasonCopy['permission']!), findsOneWidget);
    });
  });

  group('goldens', () {
    testWidgets('backup uploading', (t) async {
      await pumpBackup(
        t,
        engineWith(status(queued: 8, uploading: upload(), needsAttention: 2)),
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../goldens/backup_uploading.png'),
      );
    });

    testWidgets('backup paused', (t) async {
      await pumpBackup(
        t,
        engineWith(
          status(queued: 3, paused: true, reason: PauseReason.wifiRequired),
        ),
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../goldens/backup_paused.png'),
      );
    });
  });
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pictunnel/app/app.dart';
import 'package:pictunnel/app/router.dart';
import 'package:pictunnel/app/theme/theme.dart';
import 'package:pictunnel/core/engine/engine.dart';
import 'package:pictunnel/core/engine/fake_engine.dart';
import 'package:pictunnel/features/pairing/pairing_controller.dart';
import 'package:pictunnel/features/settings/about_screen.dart';
import 'package:pictunnel/features/settings/album_picker.dart';
import 'package:pictunnel/features/settings/settings_screen.dart';
import 'package:pictunnel/features/timeline/timeline_providers.dart';

const gb = 1 << 30;

FakeEngine settingsEngine({int freeable = 0, int queued = 0}) {
  final e = FakeEngine(
    connection: ServerConnection(
      serverId: 's',
      name: 'Home server',
      activeEndpoint: 'https://192.168.1.20:8443',
      onLan: true,
      fp16: 'AB12CD34EF56GH78',
      fpFull: 'AB12CD34EF56GH78IJ90KL12MN34OP56QR78ST90UV12',
    ),
  );
  e.status = BackupStatus(
    backedUp: 10,
    total: 10 + queued,
    queued: queued,
    needsAttention: 0,
    skipped: 0,
    freeableBytes: freeable,
    paused: false,
    preparing: 0,
    mediaAccess: MediaAccess.full,
  );
  e.settings = EngineSettings(
    wifiOnly: true,
    chargingOnly: false,
    includeVideos: true,
    keepUneditedOriginals: false,
    allAlbums: true,
    albumIds: [],
  );
  return e;
}

PhoneItem phoneItem(int i, ItemState state, {int size = 1000}) => PhoneItem(
  localId: 'p$i',
  filename: 'IMG_$i.JPG',
  takenAtMs: DateTime(2026, 10, 1).millisecondsSinceEpoch - i,
  mime: 'image/jpeg',
  size: size,
  state: state,
  isLivePhoto: false,
);

Future<FakeEngine> pumpSettings(WidgetTester t, FakeEngine e) async {
  t.view.physicalSize = const Size(390 * 2, 844 * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: SettingsScreen()),
      ),
      GoRoute(
        path: '/settings/albums',
        builder: (_, _) => const AlbumPickerScreen(),
      ),
      GoRoute(
        path: '/settings/about',
        builder: (_, _) => const AboutScreen(),
      ),
    ],
  );
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        engineProvider.overrideWithValue(e),
        deviceNameProvider.overrideWithValue('Pixel 9'),
        serverVersionProvider.overrideWith((_) async => '0.9.1'),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: darkroomTheme(),
        routerConfig: router,
      ),
    ),
  );
  await t.pumpAndSettle();
  return e;
}

void main() {
  testWidgets('toggles call setSettings', (t) async {
    final e = await pumpSettings(t, settingsEngine());
    await t.tap(find.text('Use mobile data'));
    await t.pumpAndSettle();
    expect(e.setSettingsCalls.last.wifiOnly, isFalse);

    await t.tap(find.text('Only while charging'));
    await t.pumpAndSettle();
    expect(e.setSettingsCalls.last.chargingOnly, isTrue);
    expect(e.setSettingsCalls.last.wifiOnly, isFalse);

    await t.tap(find.text('Include videos'));
    await t.pumpAndSettle();
    expect(e.setSettingsCalls.last.includeVideos, isFalse);
    expect(e.setSettingsCalls, hasLength(3));
  });

  testWidgets('unedited originals only on iOS', (t) async {
    await pumpSettings(t, settingsEngine());
    expect(find.text('Also keep unedited originals'), findsNothing);

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final e = settingsEngine();
      await pumpSettings(t, e);
      expect(find.text('Also keep unedited originals'), findsOneWidget);
      await t.tap(find.text('Also keep unedited originals'));
      await t.pumpAndSettle();
      expect(e.setSettingsCalls.single.keepUneditedOriginals, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('album picker selects albums', (t) async {
    final e = settingsEngine()
      ..albums = [
        AlbumInfo(id: 'cam', name: 'Camera', count: 1204),
        AlbumInfo(id: 'wa', name: 'WhatsApp Images', count: 1),
      ];
    await pumpSettings(t, e);
    expect(find.text('All albums'), findsOneWidget);
    await t.tap(find.byKey(const Key('albumsRow')));
    await t.pumpAndSettle();

    await t.tap(find.byKey(const Key('allAlbums')));
    await t.pumpAndSettle();
    expect(e.setSettingsCalls.last.allAlbums, isFalse);
    expect(find.byKey(const Key('noAlbumsHint')), findsOneWidget);
    expect(find.text('1,204 items'), findsOneWidget);

    await t.tap(find.text('Camera'));
    await t.pumpAndSettle();
    expect(e.setSettingsCalls.last.albumIds, ['cam']);
    expect(find.byKey(const Key('noAlbumsHint')), findsNothing);
  });

  testWidgets('a failed setSettings rolls back and explains', (t) async {
    final e = _FailingSettingsEngine();
    await pumpSettings(t, e);
    await t.tap(find.text('Include videos'));
    await t.pumpAndSettle();
    expect(
      find.text('PicTunnel needs access to your photos for this. '
          'Allow it in Settings.'),
      findsOneWidget,
    );
    final sw = t.widget<DarkroomSwitch>(
      find.descendant(
        of: find.widgetWithText(SettingsToggle, 'Include videos'),
        matching: find.byType(DarkroomSwitch),
      ),
    );
    expect(sw.value, isTrue);
  });

  group('free up space', () {
    testWidgets('shows count and bytes, frees, reports skipped reasons', (
      t,
    ) async {
      final e = settingsEngine(freeable: (2.4 * gb).round())
        ..phoneItems = [
          for (var i = 0; i < 3; i++) phoneItem(i, ItemState.backedUp),
          phoneItem(9, ItemState.queued),
        ]
        ..freeUpResult = FreeUpResult(
          freedCount: 1,
          freedBytes: (1.5 * gb).round(),
          skipped: [
            SkippedFree(localId: 'p1', reason: 'fingerprint_changed'),
            SkippedFree(localId: 'p2', reason: 'cancelled'),
          ],
        );
      await pumpSettings(t, e);
      expect(
        find.text(
          '2.4 GB of photos on this phone are already safe on your server.',
        ),
        findsOneWidget,
      );
      await t.tap(find.text('Free up 2.4 GB'));
      await t.pumpAndSettle();
      expect(find.text('Free up 2.4 GB?'), findsOneWidget);
      expect(
        find.textContaining('Removes 3 photos and videos from this phone.'),
        findsOneWidget,
      );
      expect(e.freeUpCalls, isEmpty);

      await t.tap(find.widgetWithText(FilledButton, 'Free up 2.4 GB'));
      await t.pumpAndSettle();
      expect(e.freeUpCalls, [null]);
      expect(find.text('Freed 1.5 GB'), findsOneWidget);
      expect(find.text('1 item removed from this phone.'), findsOneWidget);
      expect(find.text('2 items stay on this phone:'), findsOneWidget);
      expect(find.text('Changed since the backup'), findsOneWidget);
      expect(find.text('You chose to keep them'), findsOneWidget);

      await t.tap(find.text('Done'));
      await t.pumpAndSettle();
      expect(find.text('Freed 1.5 GB'), findsNothing);
    });

    testWidgets('engine errors show readable copy', (t) async {
      final e = settingsEngine(freeable: gb)
        ..phoneItems = [phoneItem(0, ItemState.backedUp)]
        ..freeUpError = PlatformException(code: 'no_activity');
      await pumpSettings(t, e);
      await t.tap(find.byKey(const Key('freeUpButton')));
      await t.pumpAndSettle();
      expect(
        find.textContaining('Removes 1 photo or video'),
        findsOneWidget,
      );
      await t.tap(find.widgetWithText(FilledButton, 'Free up 1.0 GB'));
      await t.pumpAndSettle();
      expect(find.text("Couldn't free up space"), findsOneWidget);
      expect(find.text('Open PicTunnel and try again.'), findsOneWidget);
    });

    testWidgets('nothing freeable hides the button', (t) async {
      await pumpSettings(t, settingsEngine());
      expect(find.byKey(const Key('freeUpButton')), findsNothing);
    });
  });

  group('server', () {
    testWidgets('shows server, connection and this phone', (t) async {
      await pumpSettings(t, settingsEngine());
      expect(find.text('Home server'), findsOneWidget);
      expect(find.text('Connected · LAN'), findsOneWidget);
      expect(find.text('Pixel 9'), findsOneWidget);
    });

    testWidgets('unpair confirms first', (t) async {
      final e = await pumpSettings(t, settingsEngine());
      await t.scrollUntilVisible(find.byKey(const Key('unpair')), 100);
      await t.tap(find.byKey(const Key('unpair')));
      await t.pumpAndSettle();
      expect(find.text('Unpair this phone?'), findsOneWidget);
      expect(e.unpairCalls, 0);

      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(e.unpairCalls, 0);

      await t.tap(find.byKey(const Key('unpair')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('confirmUnpair')));
      await t.pumpAndSettle();
      expect(e.unpairCalls, 1);
    });

    testWidgets('pair again also confirms first', (t) async {
      final e = await pumpSettings(t, settingsEngine());
      await t.scrollUntilVisible(find.byKey(const Key('pairAgain')), 100);
      await t.tap(find.byKey(const Key('pairAgain')));
      await t.pumpAndSettle();
      expect(find.text('Pair again?'), findsOneWidget);
      expect(e.unpairCalls, 0);
      await t.tap(find.byKey(const Key('confirmUnpair')));
      await t.pumpAndSettle();
      expect(e.unpairCalls, 1);
    });
  });

  testWidgets('about shows versions and registers the font licenses', (
    t,
  ) async {
    registerFontLicenses();
    await pumpSettings(t, settingsEngine());
    await t.scrollUntilVisible(find.text('About'), 100);
    await t.tap(find.text('About'));
    await t.pumpAndSettle();
    expect(find.text('0.1.0'), findsOneWidget);
    expect(find.text('0.9.1'), findsOneWidget);

    final entries = await t.runAsync(
      () => LicenseRegistry.licenses.toList(),
    );
    final packages = {for (final l in entries!) ...l.packages};
    expect(packages, containsAll(['Bricolage Grotesque', 'Figtree']));
    final figtree = entries.firstWhere((l) => l.packages.contains('Figtree'));
    expect(
      figtree.paragraphs.map((p) => p.text).join(' '),
      contains('SIL OPEN FONT LICENSE'),
    );
  });

  testWidgets('settings golden (iOS, matches A-Settings canvas)', (t) async {
    t.view.physicalSize = const Size(390 * 2, 844 * 2);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final e = settingsEngine(freeable: (2.4 * gb).round(), queued: 8);
      final container = ProviderContainer(
        overrides: [
          engineProvider.overrideWithValue(e),
          serverConnectedProvider.overrideWith((_) async => true),
          timelineMonthsProvider.overrideWithValue(
            const AsyncData(<MonthSummary>[]),
          ),
          deviceNameProvider.overrideWithValue('Pixel 9'),
        ],
      );
      addTearDown(container.dispose);
      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const PicTunnelApp(),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Settings'));
      await t.pumpAndSettle();
      await expectLater(
        find.byType(PicTunnelApp),
        matchesGoldenFile('../goldens/settings.png'),
      );
      await t.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

class _FailingSettingsEngine extends FakeEngine {
  _FailingSettingsEngine() {
    settings = settingsEngine().settings;
  }

  @override
  Future<void> setSettings(EngineSettings s) async =>
      throw PlatformException(code: 'permission');
}

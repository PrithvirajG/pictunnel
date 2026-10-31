// ignore_for_file: depend_on_referenced_packages
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/app/app.dart';
import 'package:pictunnel/app/composition.dart';
import 'package:pictunnel/app/router.dart';
import 'package:pictunnel/core/db/app_db.dart';
import 'package:pictunnel/core/engine/pigeon.g.dart';
import 'package:pictunnel/core/thumbs/thumb_image.dart';
import 'package:pictunnel/features/pairing/pairing_controller.dart';
import 'package:pictunnel/features/pairing/qr_scanner_view.dart';
import 'package:pictunnel/features/settings/server_section.dart';
import 'package:pictunnel/features/timeline/selection.dart';
import 'package:pictunnel/features/timeline/timeline_providers.dart';
import 'package:pictunnel/features/viewer/viewer_actions.dart';

import '../support/fake_adapter.dart';
import '../support/fake_qr_scanner.dart';

/// The Pigeon host API with canned answers instead of a platform channel.
class FakeHostApi extends EngineHostApi {
  ServerConnection? connection;
  var unpairCalls = 0;

  @override
  Future<ServerConnection?> serverInfo() async => connection;

  @override
  Future<String> getAccessToken() async => 'pt_at_engine';

  @override
  Future<void> start() async {}

  @override
  Future<void> unpair() async {
    unpairCalls++;
    connection = null;
  }

  @override
  Future<BackupStatus> getStatus() async => BackupStatus(
    backedUp: 0,
    total: 0,
    queued: 0,
    needsAttention: 0,
    skipped: 0,
    freeableBytes: 0,
    paused: false,
    preparing: 0,
    mediaAccess: MediaAccess.full,
  );

  @override
  Future<EngineSettings> getSettings() async => EngineSettings(
    wifiOnly: true,
    chargingOnly: false,
    includeVideos: true,
    keepUneditedOriginals: false,
    allAlbums: true,
    albumIds: [],
  );

  @override
  Future<PhoneItemPage> listPhoneItems(PageRequest req) async =>
      PhoneItemPage(items: []);

  @override
  Future<Uint8List> phoneThumbnail(String localId, int sizePx) async =>
      Uint8List(0);

  @override
  Future<List<String>> discoverServers(int timeoutMs) async => [];
}

ServerConnection paired() => ServerConnection(
  serverId: 'srv-1',
  name: 'Home server',
  activeEndpoint: 'https://192.168.1.20:8443/',
  onLan: true,
  fp16: 'AB12CD34EF56GH78',
  fpFull: 'AB12CD34EF56GH78IJ90KL12MN34OP56QR78ST90UV12',
);

class Booted {
  Booted(this.container, this.host, this.adapter);
  final ProviderContainer container;
  final FakeHostApi host;
  final FakeAdapter adapter;

  String get location =>
      container.read(routerProvider).routerDelegate.currentConfiguration.uri.path;
}

Future<Booted> boot(WidgetTester t, {ServerConnection? connection}) async {
  t.view.physicalSize = const Size(390 * 2, 844 * 2);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final host = FakeHostApi()..connection = connection;
  final adapter = FakeAdapter((req) {
    if (req.path.endsWith('/sync/snapshot')) {
      return FakeReply.json(200, {
        'assets': <Object>[],
        'has_more': false,
        'cursor': 'c1',
      });
    }
    if (req.path.endsWith('/sync/changes')) {
      return FakeReply.json(200, {
        'changes': <Object>[],
        'has_more': false,
        'next_cursor': 'c1',
      });
    }
    return FakeReply.json(404, problem('not_found', 404));
  });
  final dir = Directory.systemTemp.createTempSync('pt_boot');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final env = AppEnvironment(
    database: NativeDatabase.memory(),
    thumbDir: dir,
    deviceName: 'Pixel 9',
    host: host,
    listenToLifecycle: false,
    httpAdapter: adapter,
  );
  final container = ProviderContainer(
    overrides: [
      ...appOverrides(env),
      // The camera is the one seam a widget test can't drive.
      qrScannerProvider.overrideWithValue(FakeQrScanner()),
    ],
  );
  await t.pumpWidget(
    UncontrolledProviderScope(container: container, child: const PicTunnelApp()),
  );
  await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await t.pumpAndSettle();
  return Booted(container, host, adapter);
}

Future<void> shutDown(WidgetTester t, Booted b) async {
  await t.pumpWidget(const SizedBox.shrink());
  b.container.dispose();
  await t.pump();
}

void main() {
  testWidgets('unpaired: boots to the pairing screen', (t) async {
    final b = await boot(t);
    expect(b.location, '/pair');
    expect(find.text('Pair with your server'), findsOneWidget);
    expect(b.container.read(deviceNameProvider), 'Pixel 9');
    await shutDown(t, b);
  });

  testWidgets('paired: boots to the timeline and no override throws', (
    t,
  ) async {
    final b = await boot(t, connection: paired());
    expect(b.location, '/photos');
    final c = b.container;
    // Every seam a feature leaves for the composition root resolves.
    expect(c.read(appDbProvider), isA<AppDb>());
    c.read(apiClientProvider);
    c.read(assetsApiProvider);
    c.read(serverAssetsDaoProvider);
    c.read(thumbCacheProvider);
    c.read(mirrorSyncProvider);
    expect(c.read(viewerHostProvider), isA<EngineViewerHost>());
    expect(c.read(shareServiceProvider), isA<PlusShareService>());
    expect(c.read(playbackSourceProvider), isA<ProxyPlaybackSource>());
    expect(c.read(timelineActionsProvider), isA<ServerTimelineActions>());
    expect(c.read(viewerItemsProvider).hasError, isFalse);
    expect(c.read(libraryOwnerProvider), isNull);
    expect(c.read(timelineSectionsProvider).hasError, isFalse);

    // Mirror sync ran against the engine's endpoint, with the engine's token
    // and the client header.
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    final snap = b.adapter.requests.firstWhere(
      (r) => r.path.endsWith('/sync/snapshot'),
    );
    expect(snap.uri.toString(), startsWith('https://192.168.1.20:8443/api/v1/'));
    expect(snap.headers['Authorization'], 'Bearer pt_at_engine');
    expect(snap.headers['PicTunnel-Client'], matches(RegExp(r'^(android|ios)/')));
    final playback = c.read(playbackSourceProvider) as ProxyPlaybackSource;
    final upstream = await t.runAsync(() => playback.upstreamFor('a1'));
    expect(
      upstream.toString(),
      'https://192.168.1.20:8443/api/v1/assets/a1/playback',
    );
    await shutDown(t, b);
  });

  testWidgets('pairing remembers the owner; unpair wipes and returns to pair', (
    t,
  ) async {
    final b = await boot(t, connection: paired());
    final c = b.container;
    await t.runAsync(() async {
      await c.read(onPairedProvider)(
        PairResult(
          serverId: 'srv-1',
          serverName: 'Home server',
          userName: 'alice',
          deviceId: 'dev-1',
        ),
      );
      await c.read(libraryOwnerNameProvider.future);
    });
    expect(c.read(libraryOwnerProvider), 'alice');

    await t.runAsync(() => c.read(unpairActionProvider)());
    await t.pumpAndSettle();
    expect(b.host.unpairCalls, 1);
    expect(b.location, '/pair');
    final owner = await t.runAsync(
      () => c.read(appDbProvider).getMeta('library_owner'),
    );
    expect(owner, isNull);
    await shutDown(t, b);
  });
}

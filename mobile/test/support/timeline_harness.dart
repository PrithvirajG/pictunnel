import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pictunnel/app/theme/theme.dart';
import 'package:pictunnel/core/db/app_db.dart';
import 'package:pictunnel/core/db/server_assets_dao.dart';
import 'package:pictunnel/core/db/thumb_cache.dart';
import 'package:pictunnel/core/engine/engine.dart';
import 'package:pictunnel/core/engine/fake_engine.dart';
import 'package:pictunnel/core/thumbs/thumb_image.dart';
import 'package:pictunnel/features/timeline/selection.dart';
import 'package:pictunnel/features/timeline/timeline_model.dart';
import 'package:pictunnel/features/timeline/timeline_providers.dart';
import 'package:pictunnel/features/timeline/timeline_screen.dart';

/// 12 Oct 2026 12:00 local; "This week" covers 5 to 12 Oct.
final now = DateTime(2026, 10, 12, 12);

PhoneItem phone(
  String id,
  DateTime at, {
  String? sha,
  ItemState state = ItemState.discovered,
  String mime = 'image/jpeg',
  int? durationMs,
  bool live = false,
}) => PhoneItem(
  localId: id,
  sha256: sha,
  takenAtMs: at.millisecondsSinceEpoch,
  mime: mime,
  size: 10,
  durationMs: durationMs,
  state: state,
  isLivePhoto: live,
);

ServerAsset server(
  String id,
  String sha,
  DateTime at, {
  String kind = 'image',
  int? durationMs,
}) => ServerAsset(
  id: id,
  sha256: sha,
  sizeBytes: 10,
  mime: kind == 'video' ? 'video/mp4' : 'image/jpeg',
  kind: kind,
  filename: '$id.jpg',
  sortAt: at,
  year: at.year,
  month: at.month,
  durationMs: durationMs,
  state: 'active',
  thumbnailsReady: true,
  updatedSeq: 1,
);

class FakeDao implements ServerAssetsDao {
  FakeDao(this.assets);
  final List<ServerAsset> assets;

  @override
  Stream<List<ServerAsset>> watchMonth(int year, int month) => Stream.value([
    for (final a in assets)
      if (a.year == year && a.month == month) a,
  ]);

  @override
  Stream<List<MonthCount>> monthsWithCounts() {
    final counts = <(int, int), int>{};
    for (final a in assets) {
      counts.update((a.year, a.month), (n) => n + 1, ifAbsent: () => 1);
    }
    return Stream.value([
      for (final e in counts.entries) MonthCount(e.key.$1, e.key.$2, e.value),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Hands out a tiny file for every id; never touches the network.
class FakeThumbCache implements ThumbCache {
  FakeThumbCache(this.file);
  final File? file;
  final requests = <String>[];

  @override
  Future<File?> get(String assetId, String size) async {
    requests.add('$assetId/$size');
    return file;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RecordingActions implements TimelineActions {
  final calls = <String, List<String>>{};

  void _rec(String name, List<TimelineItem> items) =>
      calls[name] = [for (final i in items) i.key];

  @override
  Future<void> download(List<TimelineItem> items) async =>
      _rec('download', items);
  @override
  Future<void> trash(List<TimelineItem> items) async => _rec('trash', items);
  @override
  Future<void> freeUp(List<TimelineItem> items) async => _rec('freeUp', items);
}

class CountingEngine extends FakeEngine {
  var thumbCalls = 0;
  @override
  Future<Uint8List> phoneThumbnail(String localId, int sizePx) async {
    thumbCalls++;
    return Uint8List(0);
  }
}

late File tinyPng;

void setUpTinyPng() {
  setUpAll(() {
    final dir = Directory.systemTemp.createTempSync('tl_thumb');
    tinyPng = File('${dir.path}/t.png')..writeAsBytesSync(_png);
    addTearDown(() => dir.deleteSync(recursive: true));
  });
}

final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0x60, 0x60, 0x60,
  0x00, 0x00, 0x00, 0x05, 0x00, 0x01, 0x5e, 0xf3, 0x2a, 0x3a, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

Future<ProviderContainer> pumpTimeline(
  WidgetTester t, {
  required FakeEngine engine,
  List<ServerAsset> assets = const [],
  TimelineActions? actions,
  ThumbCache? cache,
  Size size = const Size(390, 844),
}) async {
  t.view.physicalSize = size * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: TimelineScreen()),
      ),
      GoRoute(
        path: '/photos/:assetKey',
        builder: (_, s) => Text('detail ${s.pathParameters['assetKey']}'),
      ),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      engineProvider.overrideWithValue(engine),
      serverAssetsDaoProvider.overrideWithValue(FakeDao(assets)),
      clockProvider.overrideWithValue(() => now),
      thumbCacheProvider.overrideWithValue(cache ?? FakeThumbCache(tinyPng)),
      if (actions != null) timelineActionsProvider.overrideWithValue(actions),
    ],
  );
  addTearDown(container.dispose);
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: darkroomTheme(),
        routerConfig: router,
      ),
    ),
  );
  await t.pumpAndSettle();
  return container;
}

/// Phone and server items covering every badge.
({FakeEngine engine, List<ServerAsset> assets}) mixed() {
  final e = FakeEngine();
  final d = DateTime(2026, 10, 10, 9);
  e.phoneItems = [
    phone('up', d, state: ItemState.uploading),
    phone('q', d.subtract(const Duration(minutes: 1)), state: ItemState.queued),
    phone(
      'bad',
      d.subtract(const Duration(minutes: 2)),
      state: ItemState.needsAttention,
    ),
    phone(
      'both',
      d.subtract(const Duration(minutes: 3)),
      sha: 'shaBoth',
      state: ItemState.backedUp,
    ),
    phone(
      'vid',
      d.subtract(const Duration(minutes: 4)),
      mime: 'video/mp4',
      durationMs: 14000,
      state: ItemState.backedUp,
    ),
    phone(
      'live',
      d.subtract(const Duration(minutes: 5)),
      live: true,
      state: ItemState.backedUp,
    ),
  ];
  final assets = [
    server('sBoth', 'shaBoth', d.subtract(const Duration(minutes: 3))),
    server('sOnly1', 'shaOnly1', DateTime(2026, 9, 20, 10)),
    server('sOnly2', 'shaOnly2', DateTime(2026, 9, 19, 10)),
    server(
      'sOnlyVid',
      'shaOnlyVid',
      DateTime(2026, 8, 3, 10),
      kind: 'video',
      durationMs: 75000,
    ),
  ];
  return (engine: e, assets: assets);
}

Finder tileOf(String key) => find.byKey(ValueKey(key));

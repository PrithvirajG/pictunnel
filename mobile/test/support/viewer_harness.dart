// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:pictunnel/app/theme/theme.dart';
import 'package:pictunnel/core/db/app_db.dart';
import 'package:pictunnel/core/db/server_assets_dao.dart';
import 'package:pictunnel/core/engine/engine.dart';
import 'package:pictunnel/core/engine/fake_engine.dart';
import 'package:pictunnel/core/thumbs/thumb_image.dart';
import 'package:pictunnel/features/timeline/timeline_model.dart';
import 'package:pictunnel/features/timeline/timeline_providers.dart';
import 'package:pictunnel/features/viewer/viewer_actions.dart';
import 'package:pictunnel/features/viewer/viewer_screen.dart';
import 'package:pictunnel_api/pictunnel_api.dart' as api;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'timeline_harness.dart';

final shot = DateTime(2026, 10, 12, 18, 42);

ServerAsset serverAsset(
  String id, {
  String kind = 'image',
  String state = 'active',
}) => ServerAsset(
  id: id,
  sha256: 'sha-$id',
  sizeBytes: 3355443,
  mime: kind == 'video' ? 'video/mp4' : 'image/jpeg',
  kind: kind,
  filename: 'IMG_$id.jpg',
  sortAt: shot,
  year: 2026,
  month: 10,
  width: 4032,
  height: 3024,
  state: state,
  thumbnailsReady: true,
  updatedSeq: 1,
);

/// An item on the server and/or the phone.
TimelineItem viewerItem(
  String id, {
  required Presence presence,
  ItemState phoneState = ItemState.backedUp,
  bool video = false,
  bool live = false,
}) {
  final onServer = presence != Presence.phoneOnly;
  final onPhone = presence != Presence.serverOnly;
  return TimelineItem(
    key: 'sha-$id',
    presence: presence,
    takenAt: shot,
    isVideo: video,
    isLive: live,
    server: onServer
        ? serverAsset(
            id,
            kind: video ? 'video' : (live ? 'live_photo' : 'image'),
          )
        : null,
    phone: onPhone
        ? PhoneItem(
            localId: 'local-$id',
            filename: 'IMG_$id.jpg',
            sha256: 'sha-$id',
            takenAtMs: shot.millisecondsSinceEpoch,
            mime: 'image/jpeg',
            size: 3355443,
            width: 4032,
            height: 3024,
            state: phoneState,
            isLivePhoto: live,
          )
        : null,
    phoneState: onPhone ? phoneState : null,
  );
}

class PhotoEngine extends FakeEngine {
  PhotoEngine() : super(connection: null);

  @override
  Future<ServerConnection?> serverInfo() async => ServerConnection(
    serverId: 'srv-1',
    name: 'Home server',
    activeEndpoint: 'https://192.168.1.20:8443',
    onLan: true,
    fp16: 'AB12CD34EF56GH78',
    fpFull: 'AB12CD34EF56GH78IJ90KL12MN34OP56QR78ST90UV12',
  );

  @override
  Future<Uint8List> phoneThumbnail(String localId, int sizePx) async =>
      tinyPngBytes;
}

Uint8List get tinyPngBytes => tinyPng.readAsBytesSync();

Response<T> ok<T>(T data) => Response<T>(
  data: data,
  statusCode: 200,
  requestOptions: RequestOptions(path: ''),
);

class FakeAssetsApi implements api.AssetsApi {
  final trashed = <List<String>>[];
  final restored = <List<String>>[];
  final purged = <List<String>>[];
  var emptied = 0;
  final originals = <String>[];

  @override
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    List<String> ids() =>
        (invocation.namedArguments[#assetIdList] as api.AssetIdList).assetIds
            .toList();
    if (name.contains('trashAssets')) {
      trashed.add(ids());
      return Future.value(
        ok(api.BulkResult((b) => b.succeeded.replace(ids()))),
      );
    }
    if (name.contains('restoreAssets')) {
      restored.add(ids());
      return Future.value(
        ok(api.BulkResult((b) => b.succeeded.replace(ids()))),
      );
    }
    if (name.contains('purgeAssets')) {
      purged.add(ids());
      return Future.value(
        ok(api.BulkResult((b) => b.succeeded.replace(ids()))),
      );
    }
    if (name.contains('emptyTrash')) {
      emptied++;
      return Future.value(ok(api.EmptyTrashResult((b) => b.purgedCount = 1)));
    }
    if (name.contains('getAssetOriginal')) {
      originals.add(invocation.namedArguments[#assetId] as String);
      return Future.value(ok(tinyPngBytes));
    }
    if (name.contains('getAsset')) {
      final id = invocation.namedArguments[#assetId] as String;
      return Future.value(
        ok(
          api.Asset(
            (b) => b
              ..id = id
              ..sha256 = 'sha-$id'
              ..sizeBytes = 3355443
              ..mime = 'image/jpeg'
              ..kind = 'photo'
              ..filename = 'IMG_$id.jpg'
              ..takenAtSource = 'exif'
              ..lat = 38.72
              ..lon = -9.14
              ..state = 'active'
              ..thumbnailsReady = true
              ..createdAt = shot.toUtc()
              ..updatedSeq = 1,
          ),
        ),
      );
    }
    return super.noSuchMethod(invocation);
  }
}

class RecordingDao implements ServerAssetsDao {
  RecordingDao([List<ServerAsset> trashed = const []]) {
    _trashed = [...trashed];
    _push();
  }

  late List<ServerAsset> _trashed;
  final _ctl = StreamController<List<ServerAsset>>.broadcast();
  final states = <String, String>{};
  final removed = <String>[];
  var removedTrashed = 0;

  void _push() => scheduleMicrotask(() => _ctl.add([..._trashed]));

  @override
  Stream<List<ServerAsset>> watchTrashed() async* {
    yield [..._trashed];
    yield* _ctl.stream;
  }

  @override
  Future<void> setState(Iterable<String> ids, String state) async {
    for (final id in ids) {
      states[id] = state;
    }
    if (state == 'active') _trashed.removeWhere((a) => ids.contains(a.id));
    _push();
  }

  @override
  Future<bool> remove(String id) async {
    removed.add(id);
    _trashed.removeWhere((a) => a.id == id);
    _push();
    return true;
  }

  @override
  Future<void> removeTrashed() async {
    removedTrashed++;
    _trashed.clear();
    _push();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeViewerHost implements ViewerHost {
  final saved = <(String, String, String)>[];
  final freed = <List<String>?>[];

  @override
  Future<String> saveToGallery(
    String assetId,
    String filename,
    String mime,
  ) async {
    saved.add((assetId, filename, mime));
    return 'content://gallery/1';
  }

  @override
  Future<FreeUpResult> freeUpSpace(List<String>? localIds) async {
    freed.add(localIds);
    return FreeUpResult(freedCount: 1, freedBytes: 10, skipped: []);
  }
}

class FakePlayback implements PlaybackSource {
  final opened = <String>[];
  var closed = 0;

  @override
  Future<PlaybackSession> open(String assetId) async {
    opened.add(assetId);
    return PlaybackSession(
      Uri.parse('https://pt.test/api/v1/assets/$assetId/playback'),
      headers: const {'Authorization': 'Bearer pt_at_test'},
      onClose: () async => closed++,
    );
  }
}

class FakeShare implements ShareService {
  final shared = <String>[];
  @override
  Future<void> shareOriginal(
    String assetId,
    String filename,
    String mime,
  ) async => shared.add(assetId);
}

/// Records what the player was asked to open; never touches the network.
class FakeVideoPlatform extends VideoPlayerPlatform {
  final sources = <DataSource>[];
  final played = <int>[];
  final disposed = <int>[];
  var _next = 0;

  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sources.add(options.dataSource);
    return ++_next;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 5),
      size: const Size(1920, 1080),
    ),
  );
  @override
  Future<void> dispose(int playerId) async => disposed.add(playerId);
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> play(int playerId) async => played.add(playerId);
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Widget buildView(int playerId) => const SizedBox.expand();
  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
}

class ViewerRig {
  ViewerRig(this.items, {List<ServerAsset> trashed = const []})
    : dao = RecordingDao(trashed);
  final List<TimelineItem> items;
  final api = FakeAssetsApi();
  final RecordingDao dao;
  final host = FakeViewerHost();
  final share = FakeShare();
  final video = FakeVideoPlatform();
  final playback = FakePlayback();

  List<Override> get overrides => [
    engineProvider.overrideWithValue(PhotoEngine()),
    viewerItemsProvider.overrideWithValue(AsyncData(items)),
    assetsApiProvider.overrideWithValue(api),
    serverAssetsDaoProvider.overrideWithValue(dao),
    viewerHostProvider.overrideWithValue(host),
    shareServiceProvider.overrideWithValue(share),
    playbackSourceProvider.overrideWithValue(playback),
    libraryOwnerProvider.overrideWithValue('alice'),
    thumbCacheProvider.overrideWithValue(FakeThumbCache(tinyPng)),
  ];
}

Future<ViewerRig> pumpViewer(
  WidgetTester t,
  List<TimelineItem> items, {
  String? open,
}) async {
  final rig = ViewerRig(items);
  VideoPlayerPlatform.instance = rig.video;
  t.view.physicalSize = const Size(390, 844) * 2;
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    ProviderScope(
      overrides: rig.overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: darkroomTheme(),
        home: ViewerScreen(assetKey: open ?? items.first.key),
      ),
    ),
  );
  await t.pump();
  await settleImages(t);
  return rig;
}

/// Image decoding runs on real threads; give it real time, then settle.
Future<void> settleImages(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await t.pump();
  }
  await t.pumpAndSettle();
}

/// Replaces the shared 1px fixture with an opaque 400x300 gradient so the
/// viewer area shows a real picture (and pinch zoom has something to scale).
void setUpViewerPhoto() {
  setUpAll(() async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    const rect = Rect.fromLTWH(0, 0, 400, 300);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7A5C3E), Color(0xFFC9964F), Color(0xFF3E5C7A)],
        ).createShader(rect),
    );
    final img = await rec.endRecording().toImage(400, 300);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory.systemTemp.createTempSync('viewer_photo');
    tinyPng = File('${dir.path}/photo.png')
      ..writeAsBytesSync(data!.buffer.asUint8List());
    addTearDown(() => dir.deleteSync(recursive: true));
  });
}

/// In-memory [Engine] for widget tests and the debug "demo" flavor.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

import 'engine.dart';

class FakeEngine implements Engine {
  FakeEngine({this.connection});

  ServerConnection? connection;

  /// Thrown by [pair] / [trustOnFirstUse] when set.
  PlatformException? pairError;
  PlatformException? trustError;

  /// Returned by [discoverServers].
  List<String> discovered = [];

  ServerIdentity identity = ServerIdentity(
    serverId: 'srv-1',
    name: 'Home server',
    fp16: 'AB12CD34EF56GH78',
    fpFull: 'AB12CD34EF56GH78IJ90KL12MN34OP56QR78ST90UV12',
    url: 'https://192.168.1.20:8443',
  );

  final pairRequests = <PairRequest>[];
  final trustRequests = <String>[];
  var startCalls = 0;
  var unpairCalls = 0;

  final _status = StreamController<BackupStatus>.broadcast();
  final _items = StreamController<PhoneItem>.broadcast();
  final _repair = StreamController<void>.broadcast();

  @override
  Stream<BackupStatus> get status$ => _status.stream;
  @override
  Stream<PhoneItem> get items$ => _items.stream;
  @override
  Stream<void> get needsRepair$ => _repair.stream;

  void emitStatus(BackupStatus s) => _status.add(s);
  void emitItem(PhoneItem i) => _items.add(i);

  /// Simulates refresh-token reuse: credentials wiped, event fired.
  void triggerRepair() {
    connection = null;
    _repair.add(null);
  }

  @override
  Future<PairResult> pair(PairRequest req) async {
    pairRequests.add(req);
    final e = pairError;
    if (e != null) throw e;
    connection = ServerConnection(
      serverId: identity.serverId,
      name: identity.name,
      activeEndpoint: req.serverUrl ?? identity.url,
      onLan: true,
      fp16: identity.fp16,
      fpFull: identity.fpFull,
    );
    return PairResult(
      serverId: identity.serverId,
      serverName: identity.name,
      userName: 'me',
      deviceId: 'dev-1',
    );
  }

  @override
  Future<ServerIdentity> trustOnFirstUse(String serverUrl) async {
    trustRequests.add(serverUrl);
    final e = trustError;
    if (e != null) throw e;
    return identity;
  }

  @override
  Future<ServerConnection?> serverInfo() async => connection;

  @override
  Future<List<String>> discoverServers(Duration timeout) async => discovered;

  @override
  Future<void> unpair() async {
    unpairCalls++;
    connection = null;
  }

  @override
  Future<void> start() async => startCalls++;

  /// Returned by [getStatus]; tests set it before pumping the screen.
  BackupStatus status = BackupStatus(
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
  EngineSettings settings = EngineSettings(
    wifiOnly: true,
    chargingOnly: false,
    includeVideos: true,
    keepUneditedOriginals: false,
    allAlbums: true,
    albumIds: [],
  );
  List<PhoneItem> _phoneItems = [];
  List<PhoneItem>? _sorted;

  /// The phone index, served in the engine's paging order (taken time, then
  /// localId, both descending).
  List<PhoneItem> get phoneItems => _phoneItems;
  set phoneItems(List<PhoneItem> items) {
    _phoneItems = items;
    _sorted = null;
  }

  /// Every [listPhoneItems] call, for tests that bound the work.
  final pageRequests = <PageRequest>[];
  List<AttentionItem> attention = [];
  List<ActivityEntry> activity = [];

  final pauseCalls = <PauseReason>[];
  final retryCalls = <List<String>>[];
  final undoSkipCalls = <String>[];
  var runNowCalls = 0;

  @override
  Future<BackupStatus> getStatus() async => status;

  @override
  Future<void> pause(PauseReason reason) async => pauseCalls.add(reason);

  @override
  Future<void> runNow() async => runNowCalls++;

  @override
  Future<EngineSettings> getSettings() async => settings;

  @override
  Future<PhoneItemPage> listPhoneItems(PageRequest req) async {
    pageRequests.add(req);
    final items = _sorted ??= [..._phoneItems]
      ..sort((a, b) {
        final t = b.takenAtMs.compareTo(a.takenAtMs);
        return t != 0 ? t : b.localId.compareTo(a.localId);
      });
    var start = 0;
    final key = req.afterKey;
    if (key != null) {
      final bar = key.indexOf('|');
      final ms = int.parse(key.substring(0, bar));
      final id = key.substring(bar + 1);
      // First item strictly after the key in the paging order.
      var lo = 0, hi = items.length;
      while (lo < hi) {
        final mid = (lo + hi) ~/ 2;
        final it = items[mid];
        final after =
            it.takenAtMs < ms ||
            (it.takenAtMs == ms && it.localId.compareTo(id) < 0);
        if (after) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      start = lo;
    }
    final end = start + req.limit < items.length
        ? start + req.limit
        : items.length;
    final last = end > start ? items[end - 1] : null;
    return PhoneItemPage(
      items: items.sublist(start, end),
      nextKey: end < items.length && last != null
          ? '${last.takenAtMs}|${last.localId}'
          : null,
    );
  }

  @override
  Future<Uint8List> phoneThumbnail(String localId, int sizePx) async =>
      Uint8List(0);

  @override
  Future<List<AttentionItem>> listAttention() async => attention;

  @override
  Future<void> retry(List<String> localIds) async {
    retryCalls.add(localIds);
    attention = attention.where((a) => !localIds.contains(a.localId)).toList();
  }

  @override
  Future<List<ActivityEntry>> listActivity(int limit) async => activity;

  @override
  Future<void> undoSkip(String sha256) async {
    undoSkipCalls.add(sha256);
    attention = attention.where((a) => a.sha256 != sha256).toList();
  }

  String accessToken = 'token-1';
  final setSettingsCalls = <EngineSettings>[];
  List<AlbumInfo> albums = [];
  final freeUpCalls = <List<String>?>[];
  FreeUpResult freeUpResult = FreeUpResult(
    freedCount: 0,
    freedBytes: 0,
    skipped: [],
  );

  /// Thrown by [freeUpSpace] when set.
  PlatformException? freeUpError;
  final saveCalls = <String>[];

  @override
  Future<String> getAccessToken() async => accessToken;

  @override
  Future<void> setSettings(EngineSettings s) async {
    setSettingsCalls.add(s);
    settings = s;
  }

  @override
  Future<List<AlbumInfo>> listAlbums() async => albums;

  @override
  Future<FreeUpResult> freeUpSpace(List<String>? localIds) async {
    freeUpCalls.add(localIds);
    final e = freeUpError;
    if (e != null) throw e;
    return freeUpResult;
  }

  @override
  Future<String> saveToGallery(
    String assetId,
    String filename,
    String mime,
  ) async {
    saveCalls.add(assetId);
    return 'saved-$assetId';
  }

  /// What [requestMediaAccess] returns.
  MediaAccess grantOnRequest = MediaAccess.full;
  var mediaAccessRequests = 0;

  @override
  Future<MediaAccess> requestMediaAccess() async {
    mediaAccessRequests++;
    return grantOnRequest;
  }
}

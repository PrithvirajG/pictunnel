/// Thin wrapper over the Pigeon [EngineHostApi] plus the engine -> Flutter
/// events exposed as broadcast streams (spec M§3).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pigeon.g.dart';

export 'pigeon.g.dart'
    show
        ActivityEntry,
        AttentionItem,
        BackupStatus,
        EngineSettings,
        ItemState,
        MediaAccess,
        PageRequest,
        PairRequest,
        PairResult,
        PauseReason,
        PhoneItem,
        PhoneItemPage,
        ServerConnection,
        ServerIdentity,
        UploadProgress;

/// What the Flutter side needs from a backup engine. Later tasks add the
/// Backup/Photos/Settings calls here as they need them.
abstract interface class Engine {
  Future<PairResult> pair(PairRequest req);
  Future<ServerIdentity> trustOnFirstUse(String serverUrl);
  Future<ServerConnection?> serverInfo();
  Future<List<String>> discoverServers(Duration timeout);
  Future<void> unpair();
  Future<void> start();
  Future<BackupStatus> getStatus();
  Future<void> pause(PauseReason reason);
  Future<void> runNow();
  Future<EngineSettings> getSettings();
  Future<PhoneItemPage> listPhoneItems(PageRequest req);
  Future<Uint8List> phoneThumbnail(String localId, int sizePx);
  Future<List<AttentionItem>> listAttention();
  Future<void> retry(List<String> localIds);
  Future<List<ActivityEntry>> listActivity(int limit);

  /// "Back up again" for content deleted from the server (a tombstone).
  Future<void> undoSkip(String sha256);

  /// Throttled by the engine to at most 4 per second.
  Stream<BackupStatus> get status$;
  Stream<PhoneItem> get items$;

  /// Fires on refresh-token reuse or revocation; the UI goes back to pairing.
  Stream<void> get needsRepair$;
}

/// The real engine: forwards to [EngineHostApi] and registers itself as the
/// [EngineEventsApi] handler.
class PigeonEngine implements Engine, EngineEventsApi {
  PigeonEngine({EngineHostApi? host, bool registerEvents = true})
    : _host = host ?? EngineHostApi() {
    if (registerEvents) EngineEventsApi.setUp(this);
  }

  final EngineHostApi _host;
  final _status = StreamController<BackupStatus>.broadcast();
  final _items = StreamController<PhoneItem>.broadcast();
  final _repair = StreamController<void>.broadcast();

  @override
  Stream<BackupStatus> get status$ => _status.stream;
  @override
  Stream<PhoneItem> get items$ => _items.stream;
  @override
  Stream<void> get needsRepair$ => _repair.stream;

  @override
  void onStatus(BackupStatus s) => _status.add(s);
  @override
  void onItemChanged(PhoneItem item) => _items.add(item);
  @override
  void onNeedsRepair() => _repair.add(null);

  @override
  Future<PairResult> pair(PairRequest req) => _host.pair(req);
  @override
  Future<ServerIdentity> trustOnFirstUse(String serverUrl) =>
      _host.trustOnFirstUse(serverUrl);
  @override
  Future<ServerConnection?> serverInfo() => _host.serverInfo();
  @override
  Future<List<String>> discoverServers(Duration timeout) =>
      _host.discoverServers(timeout.inMilliseconds);
  @override
  Future<void> unpair() => _host.unpair();
  @override
  Future<void> start() => _host.start();
  @override
  Future<BackupStatus> getStatus() => _host.getStatus();

  @override
  Future<void> pause(PauseReason reason) => _host.pause(reason);
  @override
  Future<void> runNow() => _host.runNow();
  @override
  Future<EngineSettings> getSettings() => _host.getSettings();
  @override
  Future<PhoneItemPage> listPhoneItems(PageRequest req) =>
      _host.listPhoneItems(req);
  @override
  Future<Uint8List> phoneThumbnail(String localId, int sizePx) =>
      _host.phoneThumbnail(localId, sizePx);
  @override
  Future<List<AttentionItem>> listAttention() => _host.listAttention();
  @override
  Future<void> retry(List<String> localIds) => _host.retry(localIds);
  @override
  Future<List<ActivityEntry>> listActivity(int limit) =>
      _host.listActivity(limit);
  @override
  Future<void> undoSkip(String sha256) => _host.undoSkip(sha256);

  void dispose() {
    EngineEventsApi.setUp(null);
    _status.close();
    _items.close();
    _repair.close();
  }
}

final engineProvider = Provider<Engine>((ref) {
  final engine = PigeonEngine();
  ref.onDispose(engine.dispose);
  return engine;
});

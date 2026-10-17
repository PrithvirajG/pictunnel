// Pigeon definitions for the Flutter <-> native engine bridge (spec M§3).
// Regenerate with `task gen:pigeon`; never edit the generated outputs by hand.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/core/engine/pigeon.g.dart',
    kotlinOut:
        'android/engine/src/main/kotlin/io/github/prithvirajg/pictunnel/engine/bridge/Pigeon.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'io.github.prithvirajg.pictunnel.engine.bridge',
    ),
    swiftOut: 'ios/Engine/Sources/PicTunnelEngine/Bridge/Pigeon.g.swift',
  ),
)
enum ItemState {
  discovered,
  hashed,
  queued,
  uploading,
  verifying,
  backedUp,
  skipped,
  freed,
  needsAttention,
  paused,
}

enum PauseReason {
  user,
  wifiRequired,
  chargingRequired,
  serverFull,
  quota,
  clientTooOld,
  permission,
}

class PairRequest {
  PairRequest({
    this.qrUri,
    this.serverUrl,
    this.code,
    required this.deviceName,
    this.pinnedFp,
  });
  String? qrUri;
  String? serverUrl;
  String? code;
  String deviceName;
  String? pinnedFp;
}

class PairResult {
  PairResult({
    required this.serverId,
    required this.serverName,
    required this.userName,
    required this.deviceId,
  });
  String serverId;
  String serverName;
  String userName;
  String deviceId;
}

class ServerIdentity {
  ServerIdentity({
    required this.serverId,
    required this.name,
    required this.fp16,
    required this.fpFull,
    required this.url,
  });
  String serverId;
  String name;
  String fp16;
  String fpFull;
  String url;
}

class ServerConnection {
  ServerConnection({
    required this.serverId,
    required this.name,
    required this.activeEndpoint,
    required this.onLan,
    required this.fp16,
  });
  String serverId;
  String name;
  String activeEndpoint;
  bool onLan;
  String fp16;
}

class UploadProgress {
  UploadProgress({
    required this.localId,
    required this.filename,
    required this.sentBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
  });
  String localId;
  String filename;
  int sentBytes;
  int totalBytes;
  double bytesPerSecond;
}

class BackupStatus {
  BackupStatus({
    required this.backedUp,
    required this.total,
    required this.queued,
    this.uploading,
    required this.needsAttention,
    required this.skipped,
    required this.freeableBytes,
    required this.paused,
    this.pauseReason,
    this.lastRunAtMs,
    required this.preparing,
  });
  int backedUp;
  int total;
  int queued;
  UploadProgress? uploading;
  int needsAttention;
  int skipped;
  int freeableBytes;
  bool paused;
  PauseReason? pauseReason;
  int? lastRunAtMs;
  int preparing;
}

class EngineSettings {
  EngineSettings({
    required this.wifiOnly,
    required this.chargingOnly,
    required this.includeVideos,
    required this.keepUneditedOriginals,
    required this.allAlbums,
    required this.albumIds,
  });
  bool wifiOnly;
  bool chargingOnly;
  bool includeVideos;
  bool keepUneditedOriginals;
  bool allAlbums;
  List<String> albumIds;
}

class PhoneItem {
  PhoneItem({
    required this.localId,
    this.sha256,
    required this.takenAtMs,
    required this.mime,
    required this.size,
    this.width,
    this.height,
    this.durationMs,
    required this.state,
    this.assetId,
    required this.isLivePhoto,
  });
  String localId;
  String? sha256;
  int takenAtMs;
  String mime;
  int size;
  int? width;
  int? height;
  int? durationMs;
  ItemState state;
  String? assetId;
  bool isLivePhoto;
}

class PageRequest {
  PageRequest({this.afterKey, required this.limit});
  String? afterKey;
  int limit;
}

class PhoneItemPage {
  PhoneItemPage({required this.items, this.nextKey});
  List<PhoneItem> items;
  String? nextKey;
}

class AttentionItem {
  AttentionItem({
    required this.localId,
    required this.filename,
    required this.code,
    required this.message,
    required this.attempts,
  });
  String localId;
  String filename;
  String code;
  String message;
  int attempts;
}

class ActivityEntry {
  ActivityEntry({
    required this.atMs,
    required this.kind,
    required this.message,
    this.localId,
  });
  int atMs;
  String kind;
  String message;
  String? localId;
}

class SkippedFree {
  SkippedFree({required this.localId, required this.reason});
  String localId;
  String reason;
}

class FreeUpResult {
  FreeUpResult({
    required this.freedCount,
    required this.freedBytes,
    required this.skipped,
  });
  int freedCount;
  int freedBytes;
  List<SkippedFree> skipped;
}

class AlbumInfo {
  AlbumInfo({required this.id, required this.name, required this.count});
  String id;
  String name;
  int count;
}

@HostApi()
abstract class EngineHostApi {
  @async
  PairResult pair(PairRequest req);
  @async
  ServerIdentity trustOnFirstUse(String serverUrl);
  @async
  void unpair();
  @async
  String getAccessToken();
  @async
  ServerConnection? serverInfo();
  @async
  void start();
  @async
  void pause(PauseReason reason);
  @async
  void runNow();
  @async
  BackupStatus getStatus();
  @async
  EngineSettings getSettings();
  @async
  void setSettings(EngineSettings s);
  @async
  List<AlbumInfo> listAlbums();
  @async
  PhoneItemPage listPhoneItems(PageRequest req);
  @async
  Uint8List phoneThumbnail(String localId, int sizePx);
  @async
  List<AttentionItem> listAttention();
  @async
  void retry(List<String> localIds);
  @async
  List<ActivityEntry> listActivity(int limit);
  @async
  FreeUpResult freeUpSpace(List<String>? localIds);
  @async
  void undoSkip(String sha256);
  @async
  String saveToGallery(String assetId, String filename, String mime);

  /// mDNS discovery; returns https URLs.
  @async
  List<String> discoverServers(int timeoutMs);
}

@FlutterApi()
abstract class EngineEventsApi {
  void onStatus(BackupStatus s);
  void onItemChanged(PhoneItem item);
  void onNeedsRepair();
}

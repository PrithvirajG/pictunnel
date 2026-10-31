/// Composition root: binds every seam the features expose to its real
/// implementation (the Pigeon engine, the browse API client, the Drift
/// mirror, the thumbnail cache and mirror sync).
library;

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart' show HttpClientAdapter;
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:path_provider/path_provider.dart';
import 'package:pictunnel_api/pictunnel_api.dart';

import '../core/api/api_client.dart';
import '../core/api/server_endpoint.dart';
import '../core/db/app_db.dart';
import '../core/db/server_assets_dao.dart';
import '../core/db/thumb_cache.dart';
import '../core/engine/engine.dart';
import '../core/engine/pigeon.g.dart' show EngineHostApi;
import '../core/sync/mirror_sync.dart';
import '../core/sync/sync_driver.dart';
import '../core/thumbs/thumb_image.dart';
import '../features/pairing/pairing_controller.dart';
import '../features/settings/about_screen.dart';
import '../features/settings/server_section.dart';
import '../features/timeline/selection.dart';
import '../features/timeline/timeline_providers.dart';
import '../features/viewer/viewer_actions.dart';
import 'router.dart';
import 'version.dart';

/// What the app needs from the platform before the first frame.
class AppEnvironment {
  const AppEnvironment({
    required this.database,
    required this.thumbDir,
    required this.deviceName,
    this.host,
    this.registerEvents = true,
    this.syncInterval = const Duration(seconds: 60),
    this.listenToLifecycle = true,
    this.httpAdapter,
  });

  /// Drift executor for `app.db`.
  final QueryExecutor database;

  /// Where server thumbnails are cached.
  final Directory thumbDir;

  /// Sent at pairing and shown in Settings.
  final String deviceName;

  /// The Pigeon host API; null uses the real platform channel.
  final EngineHostApi? host;
  final bool registerEvents;
  final Duration syncInterval;
  final bool listenToLifecycle;

  /// Replaces the pinned HTTP client (tests).
  final HttpClientAdapter? httpAdapter;
}

/// Reads the device name, opens the database and finds the cache directory.
Future<AppEnvironment> loadEnvironment() async {
  final cache = await getApplicationCacheDirectory();
  return AppEnvironment(
    database: driftDatabase(name: 'app'),
    thumbDir: Directory('${cache.path}${Platform.pathSeparator}thumbs'),
    deviceName: await readDeviceName(),
  );
}

/// The phone's user-visible name (Android `Settings.Global.DEVICE_NAME`,
/// iOS device name), falling back to the manufacturer and model.
Future<String> readDeviceName([DeviceInfoPlugin? plugin]) async {
  final info = plugin ?? DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return deviceNameFrom(
        name: a.name,
        manufacturer: a.manufacturer,
        model: a.model,
      );
    }
    if (Platform.isIOS) {
      final i = await info.iosInfo;
      return deviceNameFrom(name: i.name, model: i.model);
    }
  } catch (_) {
    // fall through
  }
  return fallbackDeviceName;
}

const fallbackDeviceName = 'My phone';

/// Picks the best name: the user-set [name] when present, else
/// "Manufacturer Model" (without repeating a manufacturer the model already
/// starts with), else [fallbackDeviceName]. At most 64 characters.
String deviceNameFrom({String? name, String? manufacturer, String? model}) {
  String clean(String? s) => (s ?? '').trim();
  var out = clean(name);
  if (out.isEmpty) {
    final m = clean(model), maker = clean(manufacturer);
    if (m.isEmpty) {
      out = maker;
    } else if (maker.isEmpty ||
        m.toLowerCase().startsWith(maker.toLowerCase())) {
      out = m;
    } else {
      out = '${maker[0].toUpperCase()}${maker.substring(1)} $m';
    }
  }
  if (out.isEmpty) return fallbackDeviceName;
  return out.length > 64 ? out.substring(0, 64) : out;
}

// ----------------------------------------------------------------- providers

/// The app database. Only the composition root can open it.
final appDbProvider = Provider<AppDb>(
  (ref) => throw UnimplementedError('override appDbProvider'),
);

final serverEndpointProvider = Provider<ServerEndpoint>(
  (ref) => ServerEndpoint(ref.watch(engineProvider)),
);

final tokenProviderProvider = Provider<TokenProvider>(
  (ref) => EngineTokenProvider(ref.watch(engineProvider)),
);

final mirrorSyncProvider = Provider<MirrorSync>((ref) {
  final api = ref.watch(apiClientProvider).getSyncApi();
  final sync = MirrorSync(api: api, db: ref.watch(appDbProvider));
  ref.onDispose(sync.dispose);
  return sync;
});

final apiClientProvider = Provider<PictunnelApi>(
  (ref) => throw UnimplementedError('override apiClientProvider'),
);

/// Who owns the library on the server (`<user>/<yyyy>/<mm>`), remembered at
/// pairing.
final libraryOwnerNameProvider = FutureProvider<String?>(
  (ref) => ref.watch(appDbProvider).getMeta(_ownerKey),
);

const _ownerKey = 'library_owner';
const _serverIdKey = 'server_id';

/// Removes the server mirror, the sync cursor, pairing memory and cached
/// thumbnails.
Future<void> wipeLocalData(AppDb db, Directory thumbDir) async {
  await db.transaction(() async {
    await db.delete(db.serverAssets).go();
    await db.delete(db.syncMeta).go();
    await db.delete(db.thumbEntries).go();
  });
  try {
    if (thumbDir.existsSync()) await thumbDir.delete(recursive: true);
  } on FileSystemException {
    // a leftover file is harmless; the index no longer points at it
  }
}

/// Every override the running app needs.
List<Override> appOverrides(AppEnvironment env) => [
  engineProvider.overrideWith((ref) {
    final e = PigeonEngine(host: env.host, registerEvents: env.registerEvents);
    ref.onDispose(e.dispose);
    return e;
  }),
  appDbProvider.overrideWith((ref) {
    final db = AppDb(env.database);
    ref.onDispose(db.close);
    return db;
  }),
  deviceNameProvider.overrideWithValue(env.deviceName),
  apiClientProvider.overrideWith(
    (ref) => buildServerApi(
      endpoint: ref.watch(serverEndpointProvider),
      tokens: ref.watch(tokenProviderProvider),
      clientHeader: clientHeaderFor(appVersion),
      adapter: env.httpAdapter,
    ),
  ),
  serverAssetsDaoProvider.overrideWith(
    (ref) => ServerAssetsDao(ref.watch(appDbProvider)),
  ),
  assetsApiProvider.overrideWith(
    (ref) => ref.watch(apiClientProvider).getAssetsApi(),
  ),
  thumbCacheProvider.overrideWith(
    (ref) => ThumbCache(
      api: ref.watch(assetsApiProvider),
      db: ref.watch(appDbProvider),
      dir: env.thumbDir,
    ),
  ),
  phoneIndexSourceProvider.overrideWith(
    (ref) => EnginePhoneIndexSource(ref.watch(engineProvider)),
  ),
  viewerHostProvider.overrideWith(
    (ref) => EngineViewerHost(ref.watch(engineProvider)),
  ),
  shareServiceProvider.overrideWith(PlusShareService.new),
  playbackSourceProvider.overrideWith(
    (ref) => EndpointPlaybackSource(
      ref.watch(serverEndpointProvider),
      ref.watch(tokenProviderProvider),
    ),
  ),
  libraryOwnerProvider.overrideWith(
    (ref) => ref.watch(libraryOwnerNameProvider).value,
  ),
  timelineActionsProvider.overrideWith(ServerTimelineActions.new),
  // viewerItemsProvider, serverConnectedProvider and mediaAccessProvider
  // derive from the providers above (timeline sections, engine.serverInfo,
  // BackupStatus.mediaAccess), so their defaults are already the real ones.
  localDataWiperProvider.overrideWith(
    (ref) => () async {
      await wipeLocalData(ref.read(appDbProvider), env.thumbDir);
      ref.read(serverEndpointProvider).invalidate();
      ref.invalidate(libraryOwnerNameProvider);
    },
  ),
  onPairedProvider.overrideWith(
    (ref) => (PairResult r) async {
      final db = ref.read(appDbProvider);
      final previous = await db.getMeta(_serverIdKey);
      if (previous != null && previous != r.serverId) {
        await wipeLocalData(db, env.thumbDir);
      }
      await db.setMeta(_serverIdKey, r.serverId);
      await db.setMeta(_ownerKey, r.userName);
      ref.read(serverEndpointProvider).invalidate();
      ref.invalidate(libraryOwnerNameProvider);
    },
  ),
  serverVersionProvider.overrideWith((ref) async {
    try {
      final res = await ref
          .watch(apiClientProvider)
          .getServerApi()
          .getServerInfo();
      return res.data?.version;
    } catch (_) {
      return null;
    }
  }),
  backgroundSyncProvider.overrideWith((ref) {
    final connected = ref.watch(
      serverConnectedProvider.select((v) => v.value ?? false),
    );
    if (!connected) return;
    final driver = MirrorSyncDriver(
      ref.watch(mirrorSyncProvider),
      interval: env.syncInterval,
      listenToLifecycle: env.listenToLifecycle,
    )..start();
    ref.onDispose(driver.dispose);
  }),
];

/// Video playback straight from the server (range streaming), at the
/// engine's active endpoint, with a fresh bearer token.
class EndpointPlaybackSource implements PlaybackSource {
  EndpointPlaybackSource(this._endpoint, this._tokens);
  final ServerEndpoint _endpoint;
  final TokenProvider _tokens;

  @override
  Uri playbackUrl(String assetId) {
    final c = _endpoint.current;
    final base = c == null ? '' : ServerEndpoint.baseOf(c);
    return Uri.parse('$base/api/v1/assets/$assetId/playback');
  }

  @override
  Future<Map<String, String>> headers() async {
    // Resolving here also refreshes the endpoint before the URL is used.
    await _endpoint.resolve();
    return {'Authorization': 'Bearer ${await _tokens.accessToken()}'};
  }
}

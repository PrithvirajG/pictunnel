import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pictunnel_api/pictunnel_api.dart' as api;
import 'package:share_plus/share_plus.dart';

import '../../core/api/api_client.dart';
import '../../core/engine/pigeon.g.dart' show EngineHostApi, FreeUpResult;
import '../timeline/selection.dart';
import '../timeline/timeline_model.dart';
import '../timeline/timeline_providers.dart';

/// Wired by the composition root once the API client exists.
final assetsApiProvider = Provider<api.AssetsApi>(
  (ref) => throw UnimplementedError('override assetsApiProvider'),
);

/// The phone-side calls the viewer needs: save a server original to the
/// gallery and free up phone copies.
abstract interface class ViewerHost {
  Future<String> saveToGallery(String assetId, String filename, String mime);
  Future<FreeUpResult> freeUpSpace(List<String>? localIds);
}

class PigeonViewerHost implements ViewerHost {
  PigeonViewerHost([EngineHostApi? host]) : _host = host ?? EngineHostApi();
  final EngineHostApi _host;

  @override
  Future<String> saveToGallery(String assetId, String filename, String mime) =>
      _host.saveToGallery(assetId, filename, mime);

  @override
  Future<FreeUpResult> freeUpSpace(List<String>? localIds) =>
      _host.freeUpSpace(localIds);
}

final viewerHostProvider = Provider<ViewerHost>((_) => PigeonViewerHost());

/// Where a video streams from: the authenticated playback URL (range
/// streaming) and the `Authorization` header to send with it.
abstract interface class PlaybackSource {
  Uri playbackUrl(String assetId);
  Future<Map<String, String>> headers();
}

class ApiPlaybackSource implements PlaybackSource {
  ApiPlaybackSource({required this.baseUrl, required this.tokens});
  final String baseUrl;
  final TokenProvider tokens;

  @override
  Uri playbackUrl(String assetId) => Uri.parse(
    '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/api/v1/assets/$assetId/playback',
  );

  @override
  Future<Map<String, String>> headers() async => {
    'Authorization': 'Bearer ${await tokens.accessToken()}',
  };
}

final playbackSourceProvider = Provider<PlaybackSource>(
  (ref) => throw UnimplementedError('override playbackSourceProvider'),
);

/// Shares a file from the server original (writes it to the temp dir first).
abstract interface class ShareService {
  Future<void> shareOriginal(String assetId, String filename, String mime);
}

class PlusShareService implements ShareService {
  PlusShareService(this._ref);
  final Ref _ref;

  @override
  Future<void> shareOriginal(
    String assetId,
    String filename,
    String mime,
  ) async {
    final res = await _ref
        .read(assetsApiProvider)
        .getAssetOriginal(assetId: assetId);
    final bytes = res.data;
    if (bytes == null) throw const ViewerActionException('Could not load it');
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$filename');
    await file.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: mime)]),
    );
  }
}

final shareServiceProvider = Provider<ShareService>(PlusShareService.new);

/// Owner folder shown in the info panel (`alice / 2026 / 10`); the library
/// layout is `<user>/<yyyy>/<mm>` (P§6.3). Null hides the owner segment.
final libraryOwnerProvider = Provider<String?>((_) => null);

/// A viewer action failed in a way worth telling the person.
class ViewerActionException implements Exception {
  const ViewerActionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The real trash / download / free-up actions behind
/// `timelineActionsProvider`; the selection bar and the viewer share it.
class ServerTimelineActions implements TimelineActions {
  ServerTimelineActions(this._ref);
  final Ref _ref;

  @override
  Future<void> download(List<TimelineItem> items) async {
    final host = _ref.read(viewerHostProvider);
    for (final s in downloadable(items).map((i) => i.server!)) {
      await host.saveToGallery(s.id, s.filename, s.mime);
    }
  }

  @override
  Future<void> trash(List<TimelineItem> items) async {
    final ids = [for (final i in trashable(items)) i.server!.id];
    if (ids.isEmpty) return;
    final res = await _ref
        .read(assetsApiProvider)
        .trashAssets(
          assetIdList: api.AssetIdList((b) => b.assetIds.replace(ids)),
        );
    final done = res.data?.succeeded.toList() ?? ids;
    await _ref.read(serverAssetsDaoProvider).setState(done, 'trashed');
    if (res.data != null && res.data!.failed.isNotEmpty) {
      throw const ViewerActionException('Some items could not be moved');
    }
  }

  @override
  Future<void> freeUp(List<TimelineItem> items) async {
    final ids = [for (final i in freeable(items)) i.phone!.localId];
    if (ids.isEmpty) return;
    final r = await _ref.read(viewerHostProvider).freeUpSpace(ids);
    if (r.freedCount == 0 && r.skipped.isNotEmpty) {
      throw const ViewerActionException("Couldn't free up space for this item");
    }
  }
}

/// The merged, flat, newest-first list of every timeline item, in the order
/// the viewer pages through.
final viewerItemsProvider = Provider<AsyncValue<List<TimelineItem>>>((ref) {
  final data = ref.watch(timelineSectionsProvider);
  return data.whenData((d) => [for (final s in d.sections) ...s.items]);
});

/// Full metadata (location, time zone offset) of a server asset.
final assetDetailProvider = FutureProvider.autoDispose
    .family<api.Asset?, String>((ref, id) async {
      final res = await ref.watch(assetsApiProvider).getAsset(assetId: id);
      return res.data;
    });

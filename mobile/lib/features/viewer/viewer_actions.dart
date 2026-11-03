import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pictunnel_api/pictunnel_api.dart' as api;
import 'package:share_plus/share_plus.dart';

import '../../core/engine/engine.dart';
import '../../core/engine/error_copy.dart';
import '../../core/files/safe_name.dart';
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

/// [ViewerHost] backed by the app's [Engine].
class EngineViewerHost implements ViewerHost {
  EngineViewerHost(this._engine);
  final Engine _engine;

  @override
  Future<String> saveToGallery(String assetId, String filename, String mime) =>
      _engine.saveToGallery(assetId, filename, mime);

  @override
  Future<FreeUpResult> freeUpSpace(List<String>? localIds) =>
      _engine.freeUpSpace(localIds);
}

final viewerHostProvider = Provider<ViewerHost>(
  (ref) => EngineViewerHost(ref.watch(engineProvider)),
);

/// One opened video stream: the URL (and headers) to hand to the player,
/// valid until [close] (the viewer left).
class PlaybackSession {
  PlaybackSession(this.url, {this.headers = const {}, this.onClose});

  final Uri url;
  final Map<String, String> headers;

  /// Releases what backs [url] (the proxy).
  final Future<void> Function()? onClose;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await onClose?.call();
  }
}

/// Where a video streams from (range streaming of the asset's `playback`
/// URL). The real source opens a pinned loopback proxy per session, since
/// the platform players only accept system-trusted certificates.
abstract interface class PlaybackSource {
  Future<PlaybackSession> open(String assetId);
}

final playbackSourceProvider = Provider<PlaybackSource>(
  (ref) => throw UnimplementedError('override playbackSourceProvider'),
);

/// Shares a file from the server original (writes it to the temp dir first).
abstract interface class ShareService {
  Future<void> shareOriginal(String assetId, String filename, String mime);
}

/// Streams a server original to [savePath] without holding it in memory.
typedef OriginalDownloader =
    Future<void> Function(String assetId, String savePath);

/// Wired by the composition root to the pinned API client.
final originalDownloaderProvider = Provider<OriginalDownloader>(
  (ref) => throw UnimplementedError('override originalDownloaderProvider'),
);

/// Folder under the temp dir that holds one subfolder per share.
const shareFolderName = 'pt_share';

/// Shares a server original: it is streamed into its own folder under
/// `<temp>/pt_share/`, under a sanitised name, and the folder is deleted once
/// the share sheet is done (or failed). [sweepShareFolders] removes what an
/// interrupted share left behind.
class PlusShareService implements ShareService {
  PlusShareService(
    this._ref, {
    Future<Directory> Function()? tempDir,
    Future<void> Function(XFile file)? share,
  }) : _tempDir = tempDir ?? getTemporaryDirectory,
       _share = share ?? _systemShare;

  final Ref _ref;
  final Future<Directory> Function() _tempDir;
  final Future<void> Function(XFile file) _share;
  static var _seq = 0;

  static Future<void> _systemShare(XFile file) async {
    await SharePlus.instance.share(ShareParams(files: [file]));
  }

  @override
  Future<void> shareOriginal(
    String assetId,
    String filename,
    String mime,
  ) async {
    final sep = Platform.pathSeparator;
    final root = Directory('${(await _tempDir()).path}$sep$shareFolderName');
    final dir = Directory(
      '${root.path}$sep${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
    );
    await dir.create(recursive: true);
    try {
      final file = File(
        '${dir.path}$sep${sanitizeFileName(filename, fallback: 'photo')}',
      );
      await _ref.read(originalDownloaderProvider)(assetId, file.path);
      if (!file.existsSync()) {
        throw const ViewerActionException('Could not load it');
      }
      await _share(XFile(file.path, mimeType: mime));
    } finally {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // swept at the next start
      }
    }
  }
}

/// Deletes every share folder (run at start, when no share is in progress).
Future<void> sweepShareFolders(Directory temp) async {
  final root = Directory(
    '${temp.path}${Platform.pathSeparator}$shareFolderName',
  );
  try {
    if (root.existsSync()) await root.delete(recursive: true);
  } on FileSystemException {
    // try again next start
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

  /// Engine failures carry a code; turn them into copy the person can read.
  Future<T> _engineCall<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (e) {
      throw ViewerActionException(engineErrorMessage(e));
    }
  }

  @override
  Future<void> download(List<TimelineItem> items) async {
    final host = _ref.read(viewerHostProvider);
    for (final s in downloadable(items).map((i) => i.server!)) {
      await _engineCall(() => host.saveToGallery(s.id, s.filename, s.mime));
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
    final host = _ref.read(viewerHostProvider);
    final r = await _engineCall(() => host.freeUpSpace(ids));
    if (r.freedCount == 0 && r.skipped.isNotEmpty) {
      final reason = r.skipped.first.reason;
      if (reason == 'cancelled') {
        throw const ViewerActionException('Kept on this phone');
      }
      throw ViewerActionException(
        "Couldn't free up space: ${freeUpSkipReason(reason).toLowerCase()}",
      );
    }
  }
}

/// The merged, flat, newest-first list of the loaded timeline items, in the
/// order the grid shows them and the viewer pages through. The viewer keeps
/// the months around the open item loaded (see [timelineWindowProvider]).
final viewerItemsProvider = Provider.autoDispose<AsyncValue<List<TimelineItem>>>((
  ref,
) {
  final data = ref.watch(timelineSectionsProvider);
  return data.whenData((d) => displayOrder(d.sections));
});

/// Full metadata (location, time zone offset) of a server asset.
final assetDetailProvider = FutureProvider.autoDispose
    .family<api.Asset?, String>((ref, id) async {
      final res = await ref.watch(assetsApiProvider).getAsset(assetId: id);
      return res.data;
    });

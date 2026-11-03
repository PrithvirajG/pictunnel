import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:pictunnel_api/pictunnel_api.dart';

import '../api/api_client.dart';
import '../decisions/decide.dart';
import '../files/safe_name.dart';
import 'app_db.dart';

/// On-disk LRU of server thumbnails, evicting by `lastUsedAt` once the total
/// size exceeds [budgetBytes] (default 512 MiB).
class ThumbCache {
  ThumbCache({
    required this.api,
    required this.db,
    required this.dir,
    this.budgetBytes = 512 * 1024 * 1024,
    DateTime Function()? now,
    this.scheduleRetry,
  }) : _now = now ?? DateTime.now;

  final AssetsApi api;
  final AppDb db;
  final Directory dir;
  final int budgetBytes;
  final DateTime Function() _now;

  /// Called when the server answered `404 not_ready` and `decide()` chose
  /// `retry_later`.
  final void Function(String assetId, String size)? scheduleRetry;

  /// Returns the cached thumbnail, fetching it when missing. Null when the
  /// server has not generated it yet (a retry is scheduled) or on failure.
  Future<File?> get(String assetId, String size) async {
    final hit = await (db.select(db.thumbEntries)
          ..where((t) => t.assetId.equals(assetId) & t.size.equals(size)))
        .getSingleOrNull();
    if (hit != null) {
      final f = File(hit.path);
      if (f.existsSync()) {
        await (db.update(db.thumbEntries)
              ..where((t) => t.assetId.equals(assetId) & t.size.equals(size)))
            .write(ThumbEntriesCompanion(lastUsedAt: Value(_now())));
        return f;
      }
      await _forget(assetId, size);
    }

    final Response<Uint8List> res;
    try {
      res = await api.getAssetThumbnail(
        assetId: assetId,
        size: size,
        validateStatus: (s) => s != null && s < 600,
      );
    } on DioException catch (e) {
      _decideRetry(outcomeOf(e), assetId, size);
      return null;
    }
    final status = res.statusCode ?? 0;
    final bytes = res.data;
    if (status != 200 || bytes == null) {
      _decideRetry(
          ServerOutcome(status: status, body: problemBodyOf(bytes)),
          assetId,
          size);
      return null;
    }

    await dir.create(recursive: true);
    final file = File(
      '${dir.path}${Platform.pathSeparator}'
      '${safeFileComponent(assetId)}-${safeFileComponent(size)}.jpg',
    );
    await file.writeAsBytes(bytes, flush: true);
    await db.into(db.thumbEntries).insertOnConflictUpdate(ThumbEntry(
          assetId: assetId,
          size: size,
          path: file.path,
          bytes: bytes.length,
          lastUsedAt: _now(),
        ));
    await _evict();
    return file;
  }

  void _decideRetry(ServerOutcome o, String assetId, String size) {
    final d = decide(const Given(flow: 'browse', lastAction: 'thumbnail'), o);
    if (d.action == 'retry_later') scheduleRetry?.call(assetId, size);
  }

  Future<void> _forget(String assetId, String size) =>
      (db.delete(db.thumbEntries)
            ..where((t) => t.assetId.equals(assetId) & t.size.equals(size)))
          .go();

  static const _evictBatch = 64;

  /// Sums the cache in SQL; only when it is over budget are the least
  /// recently used rows read, a small batch at a time.
  Future<void> _evict() async {
    final sum = db.thumbEntries.bytes.sum();
    final total =
        (await (db.selectOnly(db.thumbEntries)..addColumns([sum])).getSingle())
            .read(sum) ??
        0;
    var over = total - budgetBytes;
    while (over > 0) {
      final batch = await (db.select(db.thumbEntries)
            ..orderBy([(t) => OrderingTerm.asc(t.lastUsedAt)])
            ..limit(_evictBatch))
          .get();
      if (batch.isEmpty) break;
      for (final r in batch) {
        if (over <= 0) break;
        final f = File(r.path);
        if (f.existsSync()) await f.delete();
        await _forget(r.assetId, r.size);
        over -= r.bytes;
      }
    }
  }
}

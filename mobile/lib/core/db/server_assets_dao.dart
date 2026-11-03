import 'package:drift/drift.dart';
import 'package:pictunnel_api/pictunnel_api.dart' as api;

import '../time/month_key.dart';
import 'app_db.dart';

class ServerAssetsDao {
  ServerAssetsDao(this._db);

  final AppDb _db;

  static const _cursorKey = 'sync_cursor';

  static const _snapshotGenKey = 'snapshot_gen';

  /// Assets captured in [month] (by `sortAt`, in the phone's zone, as the
  /// phone index is bucketed), newest first.
  Stream<List<ServerAsset>> watchMonth(MonthKey month) {
    final q = _db.select(_db.serverAssets)
      ..where(
        (t) =>
            t.sortAt.isBiggerOrEqualValue(month.start) &
            t.sortAt.isSmallerThanValue(month.end),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.sortAt),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return q.watch();
  }

  /// Active assets per month (by `sortAt` in the phone's zone).
  ///
  /// Every zone offset is a whole number of quarter hours, so a local month
  /// boundary always falls on a quarter hour in UTC: counting per 15-minute
  /// bucket in SQL and folding the buckets into [MonthKey]s in Dart is exact
  /// and needs no row reads.
  Stream<Map<MonthKey, int>> watchMonthCounts() {
    const q =
        'SELECT sort_at - (((sort_at % 900) + 900) % 900) AS b, COUNT(*) AS n '
        "FROM server_assets WHERE state = 'active' GROUP BY b";
    return _db
        .customSelect(q, readsFrom: {_db.serverAssets})
        .watch()
        .map((rows) {
          final out = <MonthKey, int>{};
          for (final r in rows) {
            final m = MonthKey.ofMs(r.read<int>('b') * 1000);
            out[m] = (out[m] ?? 0) + r.read<int>('n');
          }
          return out;
        });
  }

  /// Trashed assets, most recently captured first.
  Stream<List<ServerAsset>> watchTrashed() {
    final q = _db.select(_db.serverAssets)
      ..where((t) => t.state.equals('trashed'))
      ..orderBy([
        (t) => OrderingTerm.desc(t.sortAt),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return q.watch();
  }

  /// Applies a trash or restore locally right after the server accepted it;
  /// the change feed later confirms it with a newer `updated_seq`.
  Future<void> setState(Iterable<String> ids, String state) =>
      (_db.update(_db.serverAssets)..where((t) => t.id.isIn(ids.toList())))
          .write(ServerAssetsCompanion(state: Value(state)));

  /// Drops every trashed row (after "Empty trash").
  Future<void> removeTrashed() =>
      (_db.delete(_db.serverAssets)..where((t) => t.state.equals('trashed')))
          .go();

  Future<ServerAsset?> byId(String id) => (_db.select(_db.serverAssets)
        ..where((t) => t.id.equals(id)))
      .getSingleOrNull();

  Future<int> total() async {
    final count = _db.serverAssets.id.count();
    final q = _db.selectOnly(_db.serverAssets)..addColumns([count]);
    return (await q.getSingle()).read(count)!;
  }

  /// Inserts or updates [a] only when it is newer than the stored row
  /// (P§7.6: older or equal `updated_seq` is ignored). Returns whether the
  /// row changed.
  Future<bool> upsert(api.Asset a) async {
    final existing = await byId(a.id);
    if (existing != null && a.updatedSeq <= existing.updatedSeq) {
      return false;
    }
    await _db
        .into(_db.serverAssets)
        .insertOnConflictUpdate(_companion(a));
    return true;
  }

  /// Returns whether a row was deleted.
  Future<bool> remove(String id) async =>
      await (_db.delete(_db.serverAssets)..where((t) => t.id.equals(id)))
          .go() >
      0;

  Future<void> clear() => _db.delete(_db.serverAssets).go();

  /// Starts a snapshot: the generation its pages mark rows with.
  Future<int> beginSnapshot() async {
    final gen = int.tryParse(await _db.getMeta(_snapshotGenKey) ?? '') ?? 0;
    await _db.setMeta(_snapshotGenKey, '${gen + 1}');
    return gen + 1;
  }

  /// Marks [ids] as listed by snapshot [gen].
  Future<void> markSeen(Iterable<String> ids, int gen) =>
      (_db.update(_db.serverAssets)..where((t) => t.id.isIn(ids.toList())))
          .write(ServerAssetsCompanion(snapshotGen: Value(gen)));

  /// After snapshot [gen] completed: removes every row it did not list.
  /// Returns how many went.
  Future<int> removeUnseen(int gen) => (_db.delete(_db.serverAssets)
        ..where((t) => t.snapshotGen.isNull() | t.snapshotGen.equals(gen).not()))
      .go();

  Future<String?> cursor() => _db.getMeta(_cursorKey);

  Future<void> setCursor(String cursor) => _db.setMeta(_cursorKey, cursor);

  Future<void> clearCursor() => _db.deleteMeta(_cursorKey);

  ServerAssetsCompanion _companion(api.Asset a) {
    // Wall-clock month: capture time shifted by its recorded offset.
    final taken = a.takenAt;
    final wall = taken != null
        ? taken.toUtc().add(Duration(minutes: a.takenAtOffsetMinutes ?? 0))
        : a.createdAt.toUtc();
    return ServerAssetsCompanion.insert(
      id: a.id,
      sha256: a.sha256,
      sizeBytes: a.sizeBytes,
      mime: a.mime,
      kind: a.kind,
      filename: a.filename,
      sortAt: (taken ?? a.createdAt).toUtc(),
      year: wall.year,
      month: wall.month,
      width: Value(a.width),
      height: Value(a.height),
      durationMs: Value(a.durationMs),
      state: a.state,
      thumbnailsReady: a.thumbnailsReady,
      updatedSeq: a.updatedSeq,
    );
  }
}

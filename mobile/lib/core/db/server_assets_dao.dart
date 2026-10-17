import 'package:drift/drift.dart';
import 'package:pictunnel_api/pictunnel_api.dart' as api;

import 'app_db.dart';

class MonthCount {
  const MonthCount(this.year, this.month, this.count);

  final int year;
  final int month;
  final int count;

  @override
  bool operator ==(Object other) =>
      other is MonthCount &&
      other.year == year &&
      other.month == month &&
      other.count == count;

  @override
  int get hashCode => Object.hash(year, month, count);

  @override
  String toString() => 'MonthCount($year-$month: $count)';
}

class ServerAssetsDao {
  ServerAssetsDao(this._db);

  final AppDb _db;

  static const _cursorKey = 'sync_cursor';

  /// Assets captured in the given month, newest first.
  Stream<List<ServerAsset>> watchMonth(int year, int month) {
    final q = _db.select(_db.serverAssets)
      ..where((t) => t.year.equals(year) & t.month.equals(month))
      ..orderBy([
        (t) => OrderingTerm.desc(t.sortAt),
        (t) => OrderingTerm.asc(t.id),
      ]);
    return q.watch();
  }

  /// Months that have assets, newest first, with their asset counts.
  Stream<List<MonthCount>> monthsWithCounts() {
    final count = _db.serverAssets.id.count();
    final q = _db.selectOnly(_db.serverAssets)
      ..addColumns([_db.serverAssets.year, _db.serverAssets.month, count])
      ..groupBy([_db.serverAssets.year, _db.serverAssets.month])
      ..orderBy([
        OrderingTerm.desc(_db.serverAssets.year),
        OrderingTerm.desc(_db.serverAssets.month),
      ]);
    return q.watch().map((rows) => [
          for (final r in rows)
            MonthCount(r.read(_db.serverAssets.year)!,
                r.read(_db.serverAssets.month)!, r.read(count)!),
        ]);
  }

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

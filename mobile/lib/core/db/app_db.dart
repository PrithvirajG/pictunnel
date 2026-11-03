import 'package:drift/drift.dart';

part 'app_db.g.dart';

/// Mirror of the server's asset metadata (sync-protocol §4.1). Only fields the
/// browse UI needs are kept. `year`/`month` are the wall-clock month of the
/// capture time (taken_at plus its offset, else created_at in UTC); the
/// timeline buckets by `sortAt` in the phone's zone instead, like the phone
/// index, so both sides agree on the month.
@DataClassName('ServerAsset')
@TableIndex(name: 'server_assets_sort_at', columns: {#sortAt})
class ServerAssets extends Table {
  TextColumn get id => text()();
  TextColumn get sha256 => text()();
  IntColumn get sizeBytes => integer()();
  TextColumn get mime => text()();
  TextColumn get kind => text()();
  TextColumn get filename => text()();
  DateTimeColumn get sortAt => dateTime()();
  IntColumn get year => integer()();
  IntColumn get month => integer()();
  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  IntColumn get durationMs => integer().nullable()();
  TextColumn get state => text()();
  BoolColumn get thumbnailsReady => boolean()();
  IntColumn get updatedSeq => integer()();

  /// The snapshot generation that last listed this row; rows a completed
  /// snapshot did not list are removed (sync-protocol §7.6 resync).
  IntColumn get snapshotGen => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Key/value store for sync state (the change-feed cursor).
class SyncMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Thumbnail files held in the on-disk LRU.
@DataClassName('ThumbEntry')
class ThumbEntries extends Table {
  TextColumn get assetId => text()();
  TextColumn get size => text()();
  TextColumn get path => text()();
  IntColumn get bytes => integer()();
  DateTimeColumn get lastUsedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {assetId, size};
}

@DriftDatabase(tables: [ServerAssets, SyncMeta, ThumbEntries])
class AppDb extends _$AppDb {
  AppDb(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.addColumn(serverAssets, serverAssets.snapshotGen);
        await m.create(serverAssetsSortAt);
      }
    },
  );

  Future<String?> getMeta(String key) async {
    final row = await (select(syncMeta)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setMeta(String key, String value) => into(syncMeta)
      .insertOnConflictUpdate(SyncMetaData(key: key, value: value));

  Future<void> deleteMeta(String key) =>
      (delete(syncMeta)..where((t) => t.key.equals(key))).go();
}

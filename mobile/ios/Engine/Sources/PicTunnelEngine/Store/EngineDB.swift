import Foundation
import GRDB

extension Item: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "items"
}

/// The engine's on-device database (M§2): items, the R3 hash cache, the PhotoKit scan cursor,
/// the activity log and settings. It lives in app storage only, so it is lost on reinstall and
/// rebuilt by rescanning and re-hashing. Every item change is written before the network call
/// it governs (R1); GRDB writes are durable when the call returns.
public final class EngineDB: Sendable {
    private let writer: any DatabaseWriter

    /// Opens (creating if needed) the database at `path` and runs pending migrations.
    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        writer = try DatabasePool(path: path, configuration: config)
        try Self.migrator.migrate(writer)
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// A private in-memory database, for tests and previews.
    public static func inMemory() throws -> EngineDB {
        try EngineDB(writer: DatabaseQueue())
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "items") { t in
                t.primaryKey("localId", .text)
                t.column("sha256", .text)
                t.column("size", .integer).notNull()
                t.column("modifiedAtMs", .integer).notNull()
                t.column("takenAtMs", .integer).notNull()
                t.column("mime", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("pairRole", .text).notNull()
                t.column("pairLocalId", .text)
                t.column("stackKey", .text)
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("durationMs", .integer)
                t.column("state", .text).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("nextAttemptAtMs", .integer)
                t.column("uploadId", .text)
                t.column("uploadUrl", .text)
                t.column("uploadOffset", .integer)
                t.column("assetId", .text)
                t.column("lastError", .text)
            }
            try db.create(index: "items_state", on: "items", columns: ["state"])
            try db.create(index: "items_taken", on: "items", columns: ["takenAtMs", "localId"])
            try db.create(index: "items_sha256", on: "items", columns: ["sha256"])

            // R3: one row per item; a lookup with a different fingerprint misses.
            try db.create(table: "hash_cache") { t in
                t.primaryKey("localId", .text)
                t.column("modifiedAtMs", .integer).notNull()
                t.column("size", .integer).notNull()
                t.column("sha256", .text).notNull()
            }
            // Archived PHPersistentChangeToken per scope (M§4.2); nil forces a full rescan.
            try db.create(table: "scan_state") { t in
                t.primaryKey("scope", .text)
                t.column("token", .blob)
            }
            try db.create(table: "activity") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("atMs", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("localId", .text)
                t.column("message", .text).notNull()
            }
            try db.create(index: "activity_at", on: "activity", columns: ["atMs"])
            try db.create(table: "settings") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }
        return m
    }

    // MARK: - items

    public func upsert(_ item: Item) throws {
        try writer.write { db in try item.upsert(db) }
    }

    public func upsertAll(_ items: [Item]) throws {
        try writer.write { db in
            for item in items { try item.upsert(db) }
        }
    }

    public func item(localId: String) throws -> Item? {
        try writer.read { db in try Item.fetchOne(db, key: localId) }
    }

    /// Items in any of `states`, newest first.
    public func items(in states: [ItemState], limit: Int) throws -> [Item] {
        try writer.read { db in
            try Item
                .filter(states.map(\.rawValue).contains(Column("state")))
                .order(Column("takenAtMs").desc, Column("localId").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Keyset page of the phone index, newest first: `takenAtMs` desc, then `localId` desc.
    /// `after` is exclusive; pass nil for the first page, then `PageKey(lastItem)`.
    public func page(after: PageKey?, limit: Int) throws -> [Item] {
        try writer.read { db in
            let taken = Column("takenAtMs")
            let localId = Column("localId")
            var request = Item.order(taken.desc, localId.desc).limit(max(limit, 0))
            if let key = after {
                request = request.filter(taken < key.takenAtMs || (taken == key.takenAtMs && localId < key.localId))
            }
            return try request.fetchAll(db)
        }
    }

    public func counts() throws -> StateCounts {
        try writer.read { db in
            var byState: [ItemState: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT state, COUNT(*) AS n FROM items GROUP BY state") {
                if let state = ItemState(rawValue: row["state"]) { byState[state] = row["n"] }
            }
            return StateCounts(byState: byState)
        }
    }

    /// Moves an item; returns false if the item is unknown.
    @discardableResult
    public func setState(
        localId: String, state: ItemState, attempts: Int, nextAttemptAtMs: Int64?, lastError: String?
    ) throws -> Bool {
        try writer.write { db in
            try Item.filter(key: localId).updateAll(db, [
                Column("state").set(to: state.rawValue),
                Column("attempts").set(to: attempts),
                Column("nextAttemptAtMs").set(to: nextAttemptAtMs),
                Column("lastError").set(to: lastError),
            ]) > 0
        }
    }

    /// Drops items from the index (and their hash cache rows); returns the items removed.
    @discardableResult
    public func delete(localIds: [String]) throws -> Int {
        try writer.write { db in
            try db.execute(literal: "DELETE FROM hash_cache WHERE localId IN \(localIds)")
            return try Item.deleteAll(db, keys: localIds)
        }
    }

    // MARK: - hash cache (R3)

    public func putHash(localId: String, modifiedAtMs: Int64, size: Int64, sha256: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO hash_cache (localId, modifiedAtMs, size, sha256) VALUES (?, ?, ?, ?)
                ON CONFLICT(localId) DO UPDATE SET
                    modifiedAtMs = excluded.modifiedAtMs, size = excluded.size, sha256 = excluded.sha256
                """,
                arguments: [localId, modifiedAtMs, size, sha256]
            )
        }
    }

    /// A hit only when the fingerprint `(modifiedAtMs, size)` is unchanged.
    public func cachedHash(localId: String, modifiedAtMs: Int64, size: Int64) throws -> String? {
        try writer.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sha256 FROM hash_cache WHERE localId = ? AND modifiedAtMs = ? AND size = ?",
                arguments: [localId, modifiedAtMs, size]
            )
        }
    }

    // MARK: - scan state

    public func scanToken(scope: String) throws -> Data? {
        try writer.read { db in
            try Data.fetchOne(db, sql: "SELECT token FROM scan_state WHERE scope = ?", arguments: [scope])
        }
    }

    public func setScanToken(scope: String, token: Data?) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO scan_state (scope, token) VALUES (?, ?)
                ON CONFLICT(scope) DO UPDATE SET token = excluded.token
                """,
                arguments: [scope, token]
            )
        }
    }

    // MARK: - activity

    @discardableResult
    public func addActivity(atMs: Int64, kind: String, localId: String?, message: String) throws -> Int64 {
        try writer.write { db in
            try db.execute(
                sql: "INSERT INTO activity (atMs, kind, localId, message) VALUES (?, ?, ?, ?)",
                arguments: [atMs, kind, localId, message]
            )
            return db.lastInsertedRowID
        }
    }

    /// Newest first.
    public func latestActivity(limit: Int) throws -> [ActivityEntry] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM activity ORDER BY id DESC LIMIT ?", arguments: [limit]).map {
                ActivityEntry(id: $0["id"], atMs: $0["atMs"], kind: $0["kind"], localId: $0["localId"],
                              message: $0["message"])
            }
        }
    }

    /// Keeps only the newest `keep` entries.
    public func trimActivity(keep: Int) throws {
        try writer.write { db in
            try db.execute(
                sql: "DELETE FROM activity WHERE id NOT IN (SELECT id FROM activity ORDER BY id DESC LIMIT ?)",
                arguments: [keep]
            )
        }
    }

    // MARK: - settings

    public func setting(_ key: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value]
            )
        }
    }

    public func allSettings() throws -> [String: String] {
        try writer.read { db in
            var out: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM settings") { out[row["key"]] = row["value"] }
            return out
        }
    }
}

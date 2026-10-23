import Foundation

/// The activity log shown in the app (M§3 `listActivity`): a ring buffer of the newest
/// `capacity` entries in the engine database.
public struct ActivityLog: Sendable {
    public static let capacity = 1000

    public static let backedUp = "backed_up"
    public static let skipped = "skipped"
    public static let needsAttention = "needs_attention"
    public static let paused = "paused"
    public static let freed = "freed"
    public static let error = "error"
    public static let info = "info"

    private let db: EngineDB
    private let clock: any Clock

    public init(db: EngineDB, clock: any Clock) {
        self.db = db
        self.clock = clock
    }

    public func add(kind: String, message: String, localId: String? = nil) throws {
        try db.addActivity(atMs: clock.nowMs(), kind: kind, localId: localId, message: message)
        try db.trimActivity(keep: Self.capacity)
    }

    /// Logging never fails the engine.
    func note(_ kind: String, _ message: String, _ localId: String? = nil) {
        try? add(kind: kind, message: message, localId: localId)
    }

    /// Newest first.
    public func latest(limit: Int) throws -> [ActivityEntry] {
        try db.latestActivity(limit: min(max(limit, 0), Self.capacity))
    }
}

import Foundation

/// Builds `BackupStatus` snapshots from the store and the uploads in flight, and pushes them to
/// `EngineEvents` at most every `minIntervalMs` (the bridge relay throttles again to 4 per second,
/// M§3). `publish(force: true)` always emits, for the end of a run.
final class StatusReporter: @unchecked Sendable {
    static let minIntervalMs: Int64 = 250

    private struct InFlight {
        var localId: String
        var filename: String
        var total: Int64
        var startedMono: Int64
        var startOffset: Int64
        var sent: Int64
        var touchedMono: Int64
    }

    private let db: EngineDB
    private let settings: SettingsRepo
    private let clock: any Clock
    private let events: any EngineEvents
    private let lock = NSLock()
    private var inFlight: [String: InFlight] = [:]
    private var lastEmitMono: Int64?

    init(db: EngineDB, settings: SettingsRepo, clock: any Clock, events: any EngineEvents) {
        self.db = db
        self.settings = settings
        self.clock = clock
        self.events = events
    }

    func uploadStarted(_ item: Item) {
        let now = clock.monotonicMs()
        let off = item.uploadOffset ?? 0
        locked {
            inFlight[item.localId] = InFlight(localId: item.localId, filename: item.filename, total: item.size,
                                              startedMono: now, startOffset: off, sent: off, touchedMono: now)
        }
    }

    /// The server confirmed `offset` bytes of the item.
    func bytesSent(_ localId: String, offset: Int64) {
        let now = clock.monotonicMs()
        locked {
            inFlight[localId]?.sent = offset
            inFlight[localId]?.touchedMono = now
        }
    }

    func uploadEnded(_ localId: String) {
        locked { inFlight[localId] = nil }
    }

    /// The most recently active upload, if any.
    func current() -> UploadProgress? {
        let now = clock.monotonicMs()
        return locked {
            guard let f = inFlight.values.max(by: { $0.touchedMono < $1.touchedMono }) else { return nil }
            let elapsed = max(now - f.startedMono, 1)
            return UploadProgress(localId: f.localId, filename: f.filename, sentBytes: f.sent, totalBytes: f.total,
                                  bytesPerSecond: Double(f.sent - f.startOffset) * 1000 / Double(elapsed))
        }
    }

    func snapshot() -> BackupStatus {
        let c = (try? db.counts()) ?? StateCounts(byState: [:])
        let pause = settings.pause()
        return BackupStatus(
            backedUp: c[.backedUp] + c[.freed],
            total: c.total,
            queued: c[.queued] + c[.uploading] + c[.verifying],
            uploading: current(),
            needsAttention: c[.needsAttention],
            skipped: c[.skipped],
            freeableBytes: (try? db.sumSize([.backedUp])) ?? 0,
            paused: pause != nil,
            pauseReason: pause?.reason,
            lastRunAtMs: settings.lastRunAtMs(),
            preparing: c[.discovered] + c[.hashed]
        )
    }

    func publish(force: Bool = false) {
        let now = clock.monotonicMs()
        let emit: Bool = locked {
            if !force, let last = lastEmitMono, now - last < Self.minIntervalMs { return false }
            lastEmitMono = now
            return true
        }
        if emit { events.status(snapshot()) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

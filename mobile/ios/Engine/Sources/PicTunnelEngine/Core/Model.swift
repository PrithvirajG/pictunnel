import Foundation

/// Wall and monotonic time. Correctness never depends on the wall clock (R10); it only schedules
/// backoff. `sleep` is the only way the engine waits, so tests can run it instantly.
public protocol Clock: Sendable {
    func nowMs() -> Int64
    func monotonicMs() -> Int64
    func sleep(ms: Int64) async
}

public struct SystemClock: Clock {
    public init() {}
    public func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    public func monotonicMs() -> Int64 { Int64(ProcessInfo.processInfo.systemUptime * 1000) }
    public func sleep(ms: Int64) async {
        try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
    }
}

/// Callbacks to the app (the Pigeon `EngineEventsApi`; the relay throttles them, M§3).
public protocol EngineEvents: Sendable {
    func status(_ s: BackupStatus)
    func itemChanged(_ i: Item)
    /// Credentials were wiped (refresh token reused or device revoked): send the UI to pairing.
    func needsRepair()
}

/// Deletes local originals through the OS confirmation (`PHAssetChangeRequest.deleteAssets`,
/// M§4.5) and returns the asset local ids the user actually confirmed. A cancelled dialog
/// returns an empty set.
public protocol Deleter: Sendable {
    func delete(_ localIds: [String]) async -> Set<String>
}

/// Limits for one run; nil means unlimited. `maxUploads` counts upload items started.
public struct RunBudget: Equatable, Sendable {
    public var maxDurationMs: Int64?
    public var maxUploads: Int?
    /// False for short runs (BGAppRefresh): a scan that would have to read the whole library (no
    /// valid change token, limited access) is left to a processing or foreground run, so a 30 s
    /// refresh never starts a full scan it cannot finish.
    public var allowFullScan: Bool

    public init(maxDurationMs: Int64? = nil, maxUploads: Int? = nil, allowFullScan: Bool = true) {
        self.maxDurationMs = maxDurationMs
        self.maxUploads = maxUploads
        self.allowFullScan = allowFullScan
    }
}

/// Why a run ended.
public enum StopReason: String, Sendable {
    /// Nothing left that is due.
    case idle
    /// The budget (or the pass limit) ran out with work left.
    case budget
    /// No endpoint is reachable; nothing counted as an attempt (R5).
    case offline
    /// The run is paused (by the user or by the server: storage, quota, client too old).
    case paused
    /// TLS failed on every endpoint, most likely a changed certificate: pair again.
    case serverUntrusted
    /// The credentials are gone (reuse or revocation): pair again.
    case needsRepair
    /// The token refresh kept failing transiently. The server may already have rotated the
    /// refresh token, so the next run must come inside its 30 s grace window (P§6.2):
    /// `RunReport.nextAttemptAtMs` says when.
    case authRetry
}

public struct RunReport: Equatable, Sendable {
    public var scanned: Int
    public var hashed: Int
    public var checked: Int
    public var backedUp: Int
    public var skipped: Int
    public var needsAttention: Int
    public var stop: StopReason
    /// When the next run should start (the earliest pending backoff, now when work is still due,
    /// or a refresh retry inside the grace window); nil when nothing waits.
    public var nextAttemptAtMs: Int64?
}

/// The upload in flight that the status shows.
public struct UploadProgress: Equatable, Sendable {
    public var localId: String
    public var filename: String
    public var sentBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double
}

/// Mirrors the Pigeon `BackupStatus`.
public struct BackupStatus: Equatable, Sendable {
    public var backedUp: Int
    public var total: Int
    public var queued: Int
    public var uploading: UploadProgress?
    public var needsAttention: Int
    public var skipped: Int
    public var freeableBytes: Int64
    public var paused: Bool
    public var pauseReason: PauseReason?
    public var lastRunAtMs: Int64?
    public var preparing: Int
}

public struct SkippedFree: Equatable, Sendable {
    public var localId: String
    public var reason: String
}

public struct FreeUpResult: Equatable, Sendable {
    public var freedCount: Int
    public var freedBytes: Int64
    public var skipped: [SkippedFree]
}

public struct PhoneItemPage: Equatable, Sendable {
    public var items: [Item]
    /// Exclusive key `"<takenAtMs>|<localId>"` for the next page; nil on the last page.
    public var nextKey: String?
}

public struct AttentionItem: Equatable, Sendable {
    public var localId: String
    public var filename: String
    public var code: String
    public var message: String
    public var attempts: Int
    /// The content hash when known ("back up again" for tombstoned content needs it).
    public var sha256: String? = nil
}

/// Engine tuning.
/// - `stagingDir`: `Application Support/staging` on device (M§6).
/// - `chunkBytes`: the single-shot limit and the chunk size, 64 MiB on iOS (smaller in tests).
/// - `checkBatchSize`: at most 1000 (R6).
/// - `maxPasses`: bounds the hash → check → upload passes of one run.
/// - `maxStagedBytes`: hashing exports into staging; new exports wait while staging holds more.
public struct EngineConfig: Sendable {
    public var stagingDir: URL
    public var chunkBytes: Int64
    public var checkBatchSize: Int
    public var maxPasses: Int
    public var maxStagedBytes: Int64

    public init(stagingDir: URL, chunkBytes: Int64 = ChunkSlicer.chunkBytes, checkBatchSize: Int = 1000,
                maxPasses: Int = 20, maxStagedBytes: Int64 = 2 << 30) {
        precondition((1...1000).contains(checkBatchSize), "check batches hold 1..1000 items (R6)")
        precondition(chunkBytes > 0)
        self.stagingDir = stagingDir
        self.chunkBytes = chunkBytes
        self.checkBatchSize = checkBatchSize
        self.maxPasses = max(1, maxPasses)
        self.maxStagedBytes = maxStagedBytes
    }
}

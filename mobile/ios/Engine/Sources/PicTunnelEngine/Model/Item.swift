/// Values of the item `kind` column (M§4.1), as in the vectors.
public enum ItemKind: String, Codable, CaseIterable, Sendable {
    case photo
    case video
    case livePhoto = "live_photo"
}

/// Values of the item `pairRole` column and of the tus `pair_role` metadata (H4).
public enum PairRole: String, Codable, CaseIterable, Sendable {
    case primary
    case liveVideo = "live_video"
}

/// R5: retryable failures an item may accumulate before it needs attention.
public let maxAttempts = 10

/// One local media item and its backup progress (M§4.1). Every change is persisted before the
/// network call it governs (R1). Times are epoch milliseconds.
public struct Item: Codable, Equatable, Hashable, Sendable {
    public var localId: String
    public var sha256: String?
    public var size: Int64
    public var modifiedAtMs: Int64
    public var takenAtMs: Int64
    public var mime: String
    public var kind: ItemKind
    public var filename: String
    public var pairRole: PairRole
    public var pairLocalId: String?
    public var stackKey: String?
    public var width: Int64?
    public var height: Int64?
    public var durationMs: Int64?
    public var state: ItemState
    public var attempts: Int
    public var nextAttemptAtMs: Int64?
    public var uploadId: String?
    public var uploadUrl: String?
    public var uploadOffset: Int64?
    public var assetId: String?
    public var lastError: String?

    public init(
        localId: String,
        sha256: String? = nil,
        size: Int64,
        modifiedAtMs: Int64,
        takenAtMs: Int64,
        mime: String,
        kind: ItemKind,
        filename: String,
        pairRole: PairRole = .primary,
        pairLocalId: String? = nil,
        stackKey: String? = nil,
        width: Int64? = nil,
        height: Int64? = nil,
        durationMs: Int64? = nil,
        state: ItemState = .discovered,
        attempts: Int = 0,
        nextAttemptAtMs: Int64? = nil,
        uploadId: String? = nil,
        uploadUrl: String? = nil,
        uploadOffset: Int64? = nil,
        assetId: String? = nil,
        lastError: String? = nil
    ) {
        self.localId = localId
        self.sha256 = sha256
        self.size = size
        self.modifiedAtMs = modifiedAtMs
        self.takenAtMs = takenAtMs
        self.mime = mime
        self.kind = kind
        self.filename = filename
        self.pairRole = pairRole
        self.pairLocalId = pairLocalId
        self.stackKey = stackKey
        self.width = width
        self.height = height
        self.durationMs = durationMs
        self.state = state
        self.attempts = attempts
        self.nextAttemptAtMs = nextAttemptAtMs
        self.uploadId = uploadId
        self.uploadUrl = uploadUrl
        self.uploadOffset = uploadOffset
        self.assetId = assetId
        self.lastError = lastError
    }
}

/// Keyset position in the phone index: newest first by `takenAtMs`, then `localId`, both
/// descending. Its string form `"<ms>|<localId>"` is the bridge's exclusive `afterKey`.
public struct PageKey: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var takenAtMs: Int64
    public var localId: String

    public init(takenAtMs: Int64, localId: String) {
        self.takenAtMs = takenAtMs
        self.localId = localId
    }

    /// The key that pages after `item`.
    public init(_ item: Item) {
        self.init(takenAtMs: item.takenAtMs, localId: item.localId)
    }

    /// Parses `"<ms>|<localId>"`; the local id may itself contain `|`.
    public init?(parsing s: String) {
        guard let bar = s.firstIndex(of: "|"), let ms = Int64(s[..<bar]) else { return nil }
        self.init(takenAtMs: ms, localId: String(s[s.index(after: bar)...]))
    }

    public var description: String { "\(takenAtMs)|\(localId)" }
}

/// Item counts by state.
public struct StateCounts: Equatable, Sendable {
    public var byState: [ItemState: Int]

    public init(byState: [ItemState: Int]) { self.byState = byState }

    public subscript(state: ItemState) -> Int { byState[state] ?? 0 }

    public var total: Int { byState.values.reduce(0, +) }
}

/// One entry of the activity log shown in the app.
public struct ActivityEntry: Equatable, Sendable {
    public var id: Int64
    public var atMs: Int64
    public var kind: String
    public var localId: String?
    public var message: String
}

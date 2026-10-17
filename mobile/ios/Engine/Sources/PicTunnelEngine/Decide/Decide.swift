import Foundation

/// Flows handled by the native engine (P§10.5). Dart owns `browse`, `pairing` and `setup`.
public enum Flow: String, Sendable {
    case backup
    case auth
    case freeUpSpace = "free_up_space"
}

/// Values of `given.last_action` for the engine flows.
public enum LastAction: String, Sendable {
    case check
    case createUpload = "create_upload"
    case appendUpload = "append_upload"
    case headUpload = "head_upload"
    case refresh
    case freeUpSpaceCheck = "free_up_space_check"

    var isUpload: Bool { self == .createUpload || self == .appendUpload || self == .headUpload }
}

/// A request that produced no response (P§10.5).
public enum Transport: String, Sendable {
    case timeout
    case reset
    case offline
}

/// The item flags of a vector `given.item`.
public struct ItemFlags: Equatable, Sendable {
    public var kind: ItemKind?
    /// Retryable failures so far (R5).
    public var attempts: Int
    /// Whether a tus session is known; nil means "infer from the last action".
    public var hasUploadId: Bool?
    /// The local file's `(modifiedAt, size)` differs from when it was hashed (P§7.8).
    public var fingerprintChanged: Bool

    public init(kind: ItemKind? = nil, attempts: Int = 0, hasUploadId: Bool? = nil, fingerprintChanged: Bool = false) {
        self.kind = kind
        self.attempts = attempts
        self.hasUploadId = hasUploadId
        self.fingerprintChanged = fingerprintChanged
    }
}

/// What the engine knew before the request that produced a `ServerOutcome` (vector `given`).
/// `itemState` is nil when the flow has no item (auth).
public struct Given: Equatable, Sendable {
    public var flow: Flow
    public var itemState: ItemState?
    public var lastAction: LastAction
    public var item: ItemFlags

    public init(flow: Flow, itemState: ItemState?, lastAction: LastAction, item: ItemFlags = ItemFlags()) {
        self.flow = flow
        self.itemState = itemState
        self.lastAction = lastAction
        self.item = item
    }
}

/// A server response, or a transport failure (`transport` set and `status` nil).
public struct ServerOutcome: Equatable, Sendable {
    public var status: Int?
    public var headers: [String: String]
    public var body: JSONValue?
    public var transport: Transport?

    public init(status: Int?, headers: [String: String] = [:], body: JSONValue? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.transport = nil
    }

    public init(transport: Transport?) {
        self.status = nil
        self.headers = [:]
        self.body = nil
        self.transport = transport
    }

    /// Header lookup; names compare case-insensitively.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// The P§10.5 action table. Raw values are the vector action names.
public enum Action: String, CaseIterable, Sendable {
    case markBackedUp = "mark_backed_up"
    case queueUpload = "queue_upload"
    case resumeUpload = "resume_upload"
    case headThenResume = "head_then_resume"
    case restartUpload = "restart_upload"
    case markSkipped = "mark_skipped"
    case rehashAndRequeue = "rehash_and_requeue"
    case backoffRetry = "backoff_retry"
    case waitRetryAfter = "wait_retry_after"
    case waitForNetwork = "wait_for_network"
    case refreshThenRetry = "refresh_then_retry"
    case retryOriginalRequest = "retry_original_request"
    case requireRepair = "require_repair"
    case pauseAllUploads = "pause_all_uploads"
    case notifyQuota = "notify_quota"
    case promptUpdate = "prompt_update"
    case markNeedsAttention = "mark_needs_attention"
    case runSnapshot = "run_snapshot"
    case retryLater = "retry_later"
    case skipThisRun = "skip_this_run"
    case uploadPrimaryFirst = "upload_primary_first"
    case uploadLiveVideo = "upload_live_video"
    case checkThenResolve = "check_then_resolve"
    case deleteLocalAllowed = "delete_local_allowed"
    case deleteLocalDenied = "delete_local_denied"
    case showError = "show_error"
    case goToLogin = "go_to_login"
}

/// The decision for one outcome. `nextState` is nil only when the flow has no item state to
/// move (for example `retry_original_request` after a refresh).
public struct Decision: Equatable, Sendable {
    public var nextState: ItemState?
    public var action: Action
    public var attemptsDelta: Int

    public init(nextState: ItemState?, action: Action, attemptsDelta: Int) {
        self.nextState = nextState
        self.action = action
        self.attemptsDelta = attemptsDelta
    }
}

/// The pure decision function (M§2.1): `(given, serverOutcome) → decision`. No I/O and no clock.
/// Encodes the problem catalogue (P§8), R2, R4, R5, R7, R11 and the attempt-counting rules of
/// P§10.5. Mirrors the Kotlin engine's `Decide` one to one.
public enum Decide {
    private static let assetIdHeader = "PicTunnel-Asset-Id"
    private static let retryAfterHeader = "Retry-After"

    public static func decide(_ g: Given, _ s: ServerOutcome) -> Decision {
        switch g.flow {
        case .auth: return auth(g, s)
        case .freeUpSpace: return freeUpSpace(g, s)
        case .backup: return escalate(g, backup(g, s))
        }
    }

    // MARK: - backup

    private static func backup(_ g: Given, _ s: ServerOutcome) -> Decision {
        let current = g.itemState
        func stay(_ action: Action, _ attempts: Int = 0) -> Decision {
            Decision(nextState: current, action: action, attemptsDelta: attempts)
        }

        if let transport = s.transport {
            // R5: no network is never an attempt; timeout and reset are.
            if transport == .offline { return stay(.waitForNetwork) }
            switch g.lastAction {
            case .createUpload, .appendUpload:
                // R2: the outcome is unknown. Ask HEAD for a known session, else check.
                return hasUploadId(g)
                    ? Decision(nextState: .uploading, action: .headThenResume, attemptsDelta: 1)
                    : Decision(nextState: .hashed, action: .checkThenResolve, attemptsDelta: 1)
            default:
                return stay(.backoffRetry, 1)
            }
        }

        guard let status = s.status else { return stay(.skipThisRun) }
        if (200...299).contains(status) { return backupSuccess(g, s, current) }
        return problem(g, s, status, current)
    }

    private static func backupSuccess(_ g: Given, _ s: ServerOutcome, _ current: ItemState?) -> Decision {
        if g.lastAction == .check {
            guard let result = results(s.body).first else {
                return Decision(nextState: current, action: .skipThisRun, attemptsDelta: 0)
            }
            switch result["verdict"]?.stringValue {
            case "exists":
                if g.item.kind == .livePhoto, result["has_live_video"]?.boolValue == false {
                    return Decision(nextState: .queued, action: .uploadLiveVideo, attemptsDelta: 0)
                }
                // R4: BackedUp only with a server asset id.
                guard let id = result["asset_id"]?.stringValue, !id.isEmpty else {
                    return Decision(nextState: current, action: .skipThisRun, attemptsDelta: 0)
                }
                return Decision(nextState: .backedUp, action: .markBackedUp, attemptsDelta: 0)
            case "missing": return Decision(nextState: .queued, action: .queueUpload, attemptsDelta: 0)
            case "partial": return Decision(nextState: .uploading, action: .resumeUpload, attemptsDelta: 0)
            case "tombstoned": return Decision(nextState: .skipped, action: .markSkipped, attemptsDelta: 0)
            default: return Decision(nextState: current, action: .skipThisRun, attemptsDelta: 0) // R7
            }
        }
        // create (201), append (204) and HEAD (200): finalized once the server names the asset.
        if let id = s.header(assetIdHeader), !id.isEmpty {
            return Decision(nextState: .backedUp, action: .markBackedUp, attemptsDelta: 0)
        }
        return Decision(nextState: .uploading, action: .resumeUpload, attemptsDelta: 0)
    }

    /// Maps a non-2xx response through the problem catalogue (P§8), then R7.
    private static func problem(_ g: Given, _ s: ServerOutcome, _ status: Int, _ current: ItemState?) -> Decision {
        func stay(_ action: Action, _ attempts: Int = 0) -> Decision {
            Decision(nextState: current, action: action, attemptsDelta: attempts)
        }
        let needsAttention = Decision(nextState: .needsAttention, action: .markNeedsAttention, attemptsDelta: 0)

        switch problemCode(s.body) {
        case "invalid_request", "forbidden", "file_too_large":
            return needsAttention
        case "unauthorized", "token_expired":
            return stay(.refreshThenRetry)
        case "refresh_token_reused":
            return Decision(nextState: .paused, action: .requireRepair, attemptsDelta: 0)
        case "not_found":
            return g.lastAction.isUpload
                ? Decision(nextState: .queued, action: .restartUpload, attemptsDelta: 0)
                : needsAttention
        case "offset_mismatch":
            return Decision(nextState: .uploading, action: .headThenResume, attemptsDelta: 0)
        case "length_mismatch", "checksum_mismatch":
            return Decision(nextState: .discovered, action: .rehashAndRequeue, attemptsDelta: 1)
        case "tombstoned":
            return Decision(nextState: .skipped, action: .markSkipped, attemptsDelta: 0)
        case "pair_primary_missing":
            return Decision(nextState: .queued, action: .uploadPrimaryFirst, attemptsDelta: 0)
        case "quota_exceeded":
            return Decision(nextState: .paused, action: .notifyQuota, attemptsDelta: 0)
        case "insufficient_storage":
            return Decision(nextState: .paused, action: .pauseAllUploads, attemptsDelta: 0)
        case "client_too_old":
            return Decision(nextState: .paused, action: .promptUpdate, attemptsDelta: 0)
        case "upload_locked", "internal":
            return stay(.backoffRetry, 1)
        case "rate_limited":
            return stay(.waitRetryAfter) // throttling is not an attempt
        case "server_unavailable":
            return serverUnavailable(s, current)
        default:
            return byStatus(s, status, current)
        }
    }

    /// R7: an unknown or missing problem code falls back to the HTTP status.
    private static func byStatus(_ s: ServerOutcome, _ status: Int, _ current: ItemState?) -> Decision {
        switch status {
        case 401: return Decision(nextState: current, action: .refreshThenRetry, attemptsDelta: 0)
        case 429: return Decision(nextState: current, action: .waitRetryAfter, attemptsDelta: 0)
        case 503: return serverUnavailable(s, current)
        case 400...499: return Decision(nextState: .needsAttention, action: .markNeedsAttention, attemptsDelta: 0)
        case 500...599: return Decision(nextState: current, action: .backoffRetry, attemptsDelta: 1)
        default: return Decision(nextState: current, action: .skipThisRun, attemptsDelta: 0)
        }
    }

    /// 503 waits for `Retry-After` when present, else backs off; it counts as an attempt.
    private static func serverUnavailable(_ s: ServerOutcome, _ current: ItemState?) -> Decision {
        Decision(
            nextState: current,
            action: s.header(retryAfterHeader) != nil ? .waitRetryAfter : .backoffRetry,
            attemptsDelta: 1
        )
    }

    /// R5: the failure that reaches `maxAttempts` stops retrying the item.
    private static func escalate(_ g: Given, _ d: Decision) -> Decision {
        guard d.attemptsDelta > 0, g.item.attempts + d.attemptsDelta >= maxAttempts else { return d }
        return Decision(nextState: .needsAttention, action: .markNeedsAttention, attemptsDelta: d.attemptsDelta)
    }

    // MARK: - auth

    /// Token refresh (P§6.2, R11). Auth failures are not item attempts.
    private static func auth(_ g: Given, _ s: ServerOutcome) -> Decision {
        let current = g.itemState
        if let transport = s.transport {
            // Network failure: keep the tokens and retry later (M§4.4).
            return Decision(nextState: current, action: transport == .offline ? .waitForNetwork : .backoffRetry,
                            attemptsDelta: 0)
        }
        guard let status = s.status else { return Decision(nextState: current, action: .skipThisRun, attemptsDelta: 0) }
        switch status {
        case 200...299:
            return Decision(nextState: current, action: .retryOriginalRequest, attemptsDelta: 0)
        case 401, 403:
            // Reused or revoked refresh credentials: wipe them and pair again.
            return Decision(nextState: .paused, action: .requireRepair, attemptsDelta: 0)
        case _ where problemCode(s.body) == "client_too_old" || status == 426:
            return Decision(nextState: .paused, action: .promptUpdate, attemptsDelta: 0)
        case 429:
            return Decision(nextState: current, action: .waitRetryAfter, attemptsDelta: 0)
        case 503 where s.header(retryAfterHeader) != nil:
            return Decision(nextState: current, action: .waitRetryAfter, attemptsDelta: 0)
        case 500...599:
            return Decision(nextState: current, action: .backoffRetry, attemptsDelta: 0)
        default:
            return Decision(nextState: current, action: .showError, attemptsDelta: 0)
        }
    }

    // MARK: - free up space

    /// P§7.8: deleting is allowed only if every result of the `confirm_on_disk` check (both
    /// components of a Live Photo) is `exists`, `active` and `on_disk`, and the local fingerprint
    /// is unchanged. `Freed` is applied only after the user confirms the OS dialog (M§4.5). Any
    /// failure keeps the local file; free-up is user-initiated, so nothing counts as an attempt.
    private static func freeUpSpace(_ g: Given, _ s: ServerOutcome) -> Decision {
        let current = g.itemState
        let denied = Decision(nextState: current, action: .deleteLocalDenied, attemptsDelta: 0)
        guard s.transport == nil, let status = s.status else { return denied }
        if status == 401 { return Decision(nextState: current, action: .refreshThenRetry, attemptsDelta: 0) }
        guard (200...299).contains(status) else { return denied }

        // The file changed since it was hashed: the server copy may differ, so re-hash.
        if g.item.fingerprintChanged {
            return Decision(nextState: .discovered, action: .deleteLocalDenied, attemptsDelta: 0)
        }

        let all = results(s.body)
        guard !all.isEmpty else { return denied }
        for r in all {
            switch r["verdict"]?.stringValue {
            case "exists": continue
            case "missing", "partial": return Decision(nextState: .queued, action: .deleteLocalDenied, attemptsDelta: 0)
            case "tombstoned": return Decision(nextState: .skipped, action: .deleteLocalDenied, attemptsDelta: 0)
            default: return denied
            }
        }
        let safe = all.allSatisfy { $0["asset_state"]?.stringValue == "active" && $0["on_disk"]?.boolValue == true }
        return safe ? Decision(nextState: .freed, action: .deleteLocalAllowed, attemptsDelta: 0) : denied
    }

    // MARK: - helpers

    /// An append or HEAD always concerns a known session; a create only when the flag says so.
    private static func hasUploadId(_ g: Given) -> Bool {
        g.item.hasUploadId ?? (g.lastAction != .createUpload)
    }

    private static func results(_ body: JSONValue?) -> [JSONValue] {
        (body?["results"]?.arrayValue ?? []).filter { if case .object = $0 { true } else { false } }
    }

    private static func problemCode(_ body: JSONValue?) -> String? {
        body?["code"]?.stringValue
    }
}

private let backoffBase: TimeInterval = 2
private let backoffCap: TimeInterval = 900

/// R5 backoff with full jitter: a uniform delay in seconds in `[0, min(cap, base * 2^(attempt-1))]`,
/// where `attempt` is the number of failures so far (1 for the first retry).
public func backoffDelay(attempt: Int, rng: inout some RandomNumberGenerator) -> TimeInterval {
    let exp = min(max(attempt - 1, 0), 30)
    let ceiling = min(backoffCap, backoffBase * Double(1 << exp))
    return Double.random(in: 0...ceiling, using: &rng)
}

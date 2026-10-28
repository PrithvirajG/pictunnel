import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a finished upload task reported: an HTTP answer (`status`, `headers`, and the body a
/// background session delivers through `didReceive data`, for problem codes), or an `error`.
public struct UploadCompletion: Sendable {
    public var taskDescription: String
    public var status: Int?
    public var headers: [String: String]
    public var body: Data?
    public var error: Error?

    public init(taskDescription: String, status: Int?, headers: [String: String], body: Data? = nil, error: Error?) {
        self.taskDescription = taskDescription
        self.status = status
        self.headers = headers
        self.body = body
        self.error = error
    }
}

/// The tus requests that carry bytes (`POST` creation and `PATCH`) go through here (M§6). On the
/// device this is the background `URLSession` `io.github.prithvirajg.pictunnel.upload`
/// (`uploadTask(with:fromFile:)`, Task 14), whose tasks outlive the app; tests and Linux use
/// `ForegroundUploader`.
///
/// Every task carries `taskDescription = "<itemId>|<uploadId>|<offset>"` (`TaskDescription`), so
/// a completion delivered after a relaunch still maps to its item row: the platform layer passes
/// each completion to `EngineController.handleUploadCompletion`, which the controller installs
/// here with `setCompletionHandler`.
public protocol BackgroundUploader: AnyObject, Sendable {
    func setCompletionHandler(_ handler: @escaping @Sendable (UploadCompletion) async -> Void)

    /// Starts `request` with `file` as its body (nil: no body). Returns once the task is handed to
    /// the session; the outcome arrives through the completion handler.
    func enqueue(request: URLRequest, file: URL?, taskDescription: String) async throws

    /// Descriptions of tasks still running in the session (after a relaunch: `getAllTasks`).
    func pendingTaskDescriptions() async -> [String]
}

/// `"<itemId>|<uploadId>|<offset>"`: the item row, the tus session (empty for the creating
/// `POST`) and the offset the request starts at. Parsed from the right, so an item id may itself
/// contain `|`.
public struct TaskDescription: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var itemId: String
    public var uploadId: String
    public var offset: Int64

    public init(itemId: String, uploadId: String, offset: Int64) {
        self.itemId = itemId
        self.uploadId = uploadId
        self.offset = offset
    }

    public init?(parsing s: String) {
        guard let last = s.lastIndex(of: "|") else { return nil }
        let head = s[..<last]
        guard let mid = head.lastIndex(of: "|"), let offset = Int64(s[s.index(after: last)...]), offset >= 0 else {
            return nil
        }
        let item = String(head[..<mid])
        guard !item.isEmpty else { return nil }
        self.init(itemId: item, uploadId: String(head[head.index(after: mid)...]), offset: offset)
    }

    /// The creating `POST` (no session yet).
    public var isCreate: Bool { uploadId.isEmpty }

    public var description: String { "\(itemId)|\(uploadId)|\(offset)" }
}

/// Where a completion goes.
enum CompletionRoute: Equatable {
    /// A run was waiting for it (or is about to).
    case delivered
    /// Nobody waits: the caller applies it, holding the item's claim, then calls `finishOrphan`.
    case orphan
    /// A duplicate, one being applied already, or stale (a run owns another task of the item).
    case ignore
}

/// Matches completions to the run waiting for them. A completion nobody waits for (after a
/// relaunch, or after the run that started it ended) is an orphan: the controller applies it on
/// its own, while the item stays claimed so no run touches it meanwhile. Tasks known to be
/// running in the session are "in flight" as well, so no run starts the same item again.
actor UploadTracker {
    private static let rememberedCompletions = 1024

    private var waiters: [String: CheckedContinuation<ServerOutcome?, Never>] = [:]
    private var early: [String: ServerOutcome] = [:]
    /// Descriptions a run is (or is about to start) waiting for.
    private var owned: Set<String> = []
    /// Descriptions running in the session (or being applied as orphans) with no waiter: item id → description.
    private var external: [String: String] = [:]
    /// Orphans being applied now.
    private var processing: Set<String> = []
    /// Completions already handled, so a duplicate delivery is a no-op.
    private var handled: Set<String> = []
    private var handledOrder: [String] = []

    func begin(_ desc: TaskDescription, owned isOwned: Bool) {
        let key = desc.description
        forgetHandled(key)
        if isOwned {
            owned.insert(key)
        } else {
            external[desc.itemId] = key
        }
    }

    /// The enqueue failed: forget the task.
    func abandon(_ desc: TaskDescription) {
        owned.remove(desc.description)
        if external[desc.itemId] == desc.description { external[desc.itemId] = nil }
    }

    /// Waits for the completion of an owned task; nil when the run detached (budget spent or the
    /// calling task was cancelled). The task keeps running in the session either way.
    func wait(_ desc: TaskDescription) async -> ServerOutcome? {
        let key = desc.description
        if let o = early.removeValue(forKey: key) {
            owned.remove(key)
            if external[desc.itemId] == key { external[desc.itemId] = nil }
            return o
        }
        guard owned.contains(key), !Task.isCancelled else {
            detach(desc)
            return nil
        }
        return await withCheckedContinuation { c in waiters[key] = c }
    }

    /// One waiting task stops waiting (its caller was cancelled); its completion becomes an orphan.
    func detach(_ desc: TaskDescription) {
        let key = desc.description
        guard owned.remove(key) != nil else { return }
        // An answer that already arrived stays in `early`; `takeEarly` hands it to the orphan path.
        external[desc.itemId] = key
        waiters.removeValue(forKey: key)?.resume(returning: nil)
    }

    /// Routes a completion.
    func complete(_ key: String, _ outcome: ServerOutcome) -> CompletionRoute {
        if let c = waiters.removeValue(forKey: key) {
            owned.remove(key)
            remember(key)
            c.resume(returning: outcome)
            return .delivered
        }
        if owned.contains(key) {
            if early[key] != nil { return .ignore }
            early[key] = outcome
            remember(key)
            return .delivered
        }
        if handled.contains(key) || processing.contains(key) { return .ignore }
        if let d = TaskDescription(parsing: key),
           owned.contains(where: { TaskDescription(parsing: $0)?.itemId == d.itemId }) {
            // A run is already acting on this item with another task: this answer is stale.
            return .ignore
        }
        processing.insert(key)
        if let d = TaskDescription(parsing: key) { external[d.itemId] = key }
        return .orphan
    }

    /// The orphan was applied (and any follow-up task started): release the item's claim.
    func finishOrphan(_ key: String) {
        processing.remove(key)
        remember(key)
        if let d = TaskDescription(parsing: key), external[d.itemId] == key { external[d.itemId] = nil }
    }

    /// The run ends: its tasks keep running in the session, and their completions become orphans.
    func detachAll() {
        for (key, c) in waiters {
            if let d = TaskDescription(parsing: key) { external[d.itemId] = key }
            c.resume(returning: nil)
        }
        for key in owned where waiters[key] == nil {
            if let d = TaskDescription(parsing: key) { external[d.itemId] = key }
        }
        waiters.removeAll()
        owned.removeAll()
        // Answers that arrived before anyone waited are applied as orphans by `takeEarly`.
    }

    /// Completions that arrived for detached tasks before their run waited: the caller applies them.
    func takeEarly() -> [(String, ServerOutcome)] {
        let out = early.filter { !owned.contains($0.key) }
        for k in out.keys {
            early[k] = nil
            processing.insert(k)
            handled.remove(k)
        }
        return out.map { ($0.key, $0.value) }
    }

    /// After a relaunch: the session's running tasks, as reported by the uploader. Each is cleared
    /// by its completion, which the session always delivers (even for a task the OS cancelled).
    func restore(_ descs: [String]) {
        for s in descs {
            guard let d = TaskDescription(parsing: s), !owned.contains(s), !handled.contains(s) else { continue }
            if external[d.itemId] == nil { external[d.itemId] = s }
        }
    }

    func isInFlight(_ itemId: String) -> Bool {
        if external[itemId] != nil { return true }
        return owned.contains { TaskDescription(parsing: $0)?.itemId == itemId }
    }

    /// Whether another task of the item still needs the chunk file at `offset`.
    func chunkInUse(itemId: String, offset: Int64, except key: String) -> Bool {
        allDescriptions().contains { k in
            guard k != key, let d = TaskDescription(parsing: k) else { return false }
            return d.itemId == itemId && d.offset == offset && !d.isCreate
        }
    }

    /// Every task description the session may still be running (owned or external).
    func allDescriptions() -> Set<String> { owned.union(external.values) }

    private func remember(_ key: String) {
        guard handled.insert(key).inserted else { return }
        handledOrder.append(key)
        if handledOrder.count > Self.rememberedCompletions {
            handled.remove(handledOrder.removeFirst())
        }
    }

    /// A description reused for a new task (a retry after `401`, or the same offset after a restart).
    private func forgetHandled(_ key: String) {
        if handled.remove(key) != nil { handledOrder.removeAll { $0 == key } }
    }
}

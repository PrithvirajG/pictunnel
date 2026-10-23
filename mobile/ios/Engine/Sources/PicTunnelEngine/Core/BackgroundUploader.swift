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

/// Matches completions to the run waiting for them. A completion nobody waits for (after a
/// relaunch, or after the run that started it ended) is an orphan: the controller applies it on
/// its own. Tasks known to be running in the session are "in flight", so no run starts the same
/// item again.
actor UploadTracker {
    private var waiters: [String: CheckedContinuation<ServerOutcome?, Never>] = [:]
    private var early: [String: ServerOutcome] = [:]
    /// Descriptions a run is (or is about to start) waiting for.
    private var owned: Set<String> = []
    /// Descriptions running in the session with no waiter: item id → description.
    private var external: [String: String] = [:]

    func begin(_ desc: TaskDescription, owned isOwned: Bool) {
        if isOwned {
            owned.insert(desc.description)
        } else {
            external[desc.itemId] = desc.description
        }
    }

    /// The enqueue failed: forget the task.
    func abandon(_ desc: TaskDescription) {
        owned.remove(desc.description)
        if external[desc.itemId] == desc.description { external[desc.itemId] = nil }
    }

    /// Waits for the completion of an owned task; nil when the run detached (budget spent).
    func wait(_ desc: TaskDescription) async -> ServerOutcome? {
        let key = desc.description
        if let o = early.removeValue(forKey: key) {
            owned.remove(key)
            return o
        }
        guard owned.contains(key) else { return nil }
        return await withCheckedContinuation { c in waiters[key] = c }
    }

    /// Delivers a completion; false when nobody owns it (an orphan for the controller to apply).
    func complete(_ desc: String, _ outcome: ServerOutcome) -> Bool {
        if let c = waiters.removeValue(forKey: desc) {
            owned.remove(desc)
            c.resume(returning: outcome)
            return true
        }
        if owned.contains(desc) {
            early[desc] = outcome
            return true
        }
        if let d = TaskDescription(parsing: desc), external[d.itemId] == desc { external[d.itemId] = nil }
        return false
    }

    /// The run ends: its tasks keep running in the session, and their completions become orphans.
    func detachAll() {
        for (key, c) in waiters {
            if let d = TaskDescription(parsing: key) { external[d.itemId] = key }
            c.resume(returning: nil)
        }
        for key in owned where waiters[key] == nil && early[key] == nil {
            if let d = TaskDescription(parsing: key) { external[d.itemId] = key }
        }
        waiters.removeAll()
        owned.removeAll()
    }

    /// After a relaunch: the session's running tasks, as reported by the uploader. Each is cleared
    /// by its completion, which the session always delivers (even for a task the OS cancelled).
    func restore(_ descs: [String]) {
        for s in descs {
            guard let d = TaskDescription(parsing: s), !owned.contains(s) else { continue }
            external[d.itemId] = s
        }
    }

    func isInFlight(_ itemId: String) -> Bool {
        if external[itemId] != nil { return true }
        return owned.contains { TaskDescription(parsing: $0)?.itemId == itemId }
    }

    /// Every task description the session may still be running (owned or external).
    func allDescriptions() -> Set<String> { owned.union(external.values) }
}

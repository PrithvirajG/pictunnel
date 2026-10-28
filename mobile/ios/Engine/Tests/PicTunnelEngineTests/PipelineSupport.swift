import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PicTunnelEngine

// MARK: - clock, events, deleter

/// A settable wall and monotonic clock. `sleep` advances both instantly and records the time.
final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Int64 = 1_760_000_000_000
    private var _mono: Int64 = 1_000
    private var _slept: [Int64] = []

    func nowMs() -> Int64 { locked { _now } }
    func monotonicMs() -> Int64 { locked { _mono } }

    func sleep(ms: Int64) async {
        locked {
            _slept.append(ms)
            _now += ms
            _mono += ms
        }
    }

    func advance(_ ms: Int64) {
        locked {
            _now += ms
            _mono += ms
        }
    }

    /// Moves only the wall clock (R10: the device clock jumped).
    func setWall(_ ms: Int64) { locked { _now = ms } }

    var slept: [Int64] { locked { _slept } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lockSync()
        defer { lock.unlockSync() }
        return body()
    }
}

final class RecordingEvents: EngineEvents, @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [BackupStatus] = []
    private var _changed: [Item] = []
    private var _repairs = 0

    func status(_ s: BackupStatus) { lock.lockSync(); _statuses.append(s); lock.unlockSync() }
    func itemChanged(_ i: Item) { lock.lockSync(); _changed.append(i); lock.unlockSync() }
    func needsRepair() { lock.lockSync(); _repairs += 1; lock.unlockSync() }

    var statuses: [BackupStatus] { lock.lockSync(); defer { lock.unlockSync() }; return _statuses }
    var repairs: Int { lock.lockSync(); defer { lock.unlockSync() }; return _repairs }
}

final class FakeDeleter: Deleter, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    let confirm: @Sendable ([String]) -> Set<String>

    init(confirm: @escaping @Sendable ([String]) -> Set<String> = { Set($0) }) { self.confirm = confirm }

    func delete(_ localIds: [String]) async -> Set<String> {
        lock.lockSync(); _calls.append(localIds); lock.unlockSync()
        return confirm(localIds)
    }

    var calls: [[String]] { lock.lockSync(); defer { lock.unlockSync() }; return _calls }
}

// MARK: - photo library

/// An in-memory photo library. Every scan is a full rescan. Exports are counted per resource.
final class FakeLibrary: PhotoLibrary, @unchecked Sendable {
    struct Res {
        var bytes: Data
        var modifiedAtMs: Int64
        var mime: String
        var filename: String
    }

    struct Asset {
        var kind: ItemKind
        var takenAtMs: Int64
        var resources: [ResourceRole: Res]
    }

    private let lock = NSLock()
    private var assets: [String: Asset] = [:]
    private var order: [String] = []
    private var _exports: [String] = []
    private var _scans = 0
    private var seq: Int64 = 0
    private var changedAt: [String: Int64] = [:]
    private var removedAt: [String: Int64] = [:]

    /// Records a change for incremental scans (the change token is the sequence number).
    private func touch(_ id: String, removed: Bool = false) {
        seq += 1
        if removed { removedAt[id] = seq; changedAt[id] = nil } else { changedAt[id] = seq; removedAt[id] = nil }
    }
    /// Called before each export with the export count so far (1-based); may throw.
    var onExport: @Sendable (Int, String) throws -> Void = { _, _ in }

    func put(_ id: String, _ bytes: Data, modifiedAtMs: Int64 = 100, takenAtMs: Int64? = nil,
             kind: ItemKind = .photo, mime: String = "image/jpeg") {
        locked {
            if assets[id] == nil { order.append(id) }
            touch(id)
            assets[id] = Asset(kind: kind, takenAtMs: takenAtMs ?? Int64(1_000 + order.count),
                               resources: [.primary: Res(bytes: bytes, modifiedAtMs: modifiedAtMs, mime: mime,
                                                         filename: "\(id).jpg")])
        }
    }

    func putLive(_ id: String, still: Data, video: Data, takenAtMs: Int64 = 5_000) {
        locked {
            if assets[id] == nil { order.append(id) }
            touch(id)
            assets[id] = Asset(kind: .livePhoto, takenAtMs: takenAtMs, resources: [
                .primary: Res(bytes: still, modifiedAtMs: 100, mime: "image/heic", filename: "\(id).HEIC"),
                .liveVideo: Res(bytes: video, modifiedAtMs: 100, mime: "video/quicktime", filename: "\(id).MOV"),
            ])
        }
    }

    /// An edit in Photos: the current rendition changes and the unedited original stays available.
    func edit(_ id: String, rendition: Data, modifiedAtMs: Int64) {
        locked {
            guard var a = assets[id], let old = a.resources[.primary] else { return }
            if a.resources[.original] == nil {
                a.resources[.original] = Res(bytes: old.bytes, modifiedAtMs: modifiedAtMs, mime: old.mime,
                                             filename: old.filename)
            } else {
                a.resources[.original]?.modifiedAtMs = modifiedAtMs
            }
            a.resources[.primary] = Res(bytes: rendition, modifiedAtMs: modifiedAtMs, mime: "image/jpeg",
                                        filename: "FullSizeRender.jpg")
            assets[id] = a
            touch(id)
        }
    }

    func remove(_ id: String) {
        locked {
            assets[id] = nil
            order.removeAll { $0 == id }
            touch(id, removed: true)
        }
    }

    var exports: [String] { locked { _exports } }
    var scans: Int { locked { _scans } }

    func scan(since token: Data?, settings: EngineSettings) async throws -> LibraryScan {
        locked {
            _scans += 1
            // A token is the change sequence it was issued at; nil or unknown means a full rescan.
            let since = token.flatMap { Int64(String(decoding: $0, as: UTF8.self).dropFirst()) }
            var out: [LibraryResource] = []
            for id in order {
                guard let a = assets[id] else { continue }
                if let since, (changedAt[id] ?? 0) <= since { continue }
                if a.kind == .video, !settings.includeVideos { continue }
                for role in ResourceRole.allCases {
                    guard let r = a.resources[role] else { continue }
                    out.append(LibraryResource(
                        assetLocalId: id, role: role, size: Int64(r.bytes.count), modifiedAtMs: r.modifiedAtMs,
                        takenAtMs: a.takenAtMs, mime: r.mime, kind: role == .liveVideo ? .video : a.kind,
                        filename: r.filename, width: 4032, height: 3024, durationMs: role == .liveVideo ? 3000 : nil))
                }
            }
            let removed = since.map { s in removedAt.filter { $0.value > s }.map(\.key) } ?? []
            return LibraryScan(changed: out, removedAssets: removed, token: Data("s\(seq)".utf8), fullRescan: since == nil)
        }
    }

    func fingerprint(assetLocalId: String, role: ResourceRole) async -> Fingerprint? {
        locked {
            guard let r = assets[assetLocalId]?.resources[role] else { return nil }
            return Fingerprint(modifiedAtMs: r.modifiedAtMs, size: Int64(r.bytes.count))
        }
    }

    func exportResource(assetLocalId: String, role: ResourceRole, to file: URL) async throws -> ExportedResource {
        let (n, res): (Int, Res?) = locked {
            _exports.append("\(assetLocalId)#\(role.rawValue)")
            return (_exports.count, assets[assetLocalId]?.resources[role])
        }
        try onExport(n, assetLocalId)
        guard let res else { throw CocoaError(.fileNoSuchFile) }
        try res.bytes.write(to: file)
        return ExportedResource(file: file, size: Int64(res.bytes.count), sha256: sha256Hex(res.bytes))
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lockSync()
        defer { lock.unlockSync() }
        return try body()
    }
}

// MARK: - background uploader

/// A `BackgroundUploader` whose "session" is the stub server. Completions arrive asynchronously,
/// as from a real session. Tasks can be held (still running in the OS) and released later, fail
/// with a transport error, or reach the server and lose the response.
final class FakeUploader: BackgroundUploader, @unchecked Sendable {
    struct Sent {
        let desc: String
        let request: Recorded
        let file: URL?
    }

    private let lock = NSLock()
    private var handler: (@Sendable (UploadCompletion) async -> Void)?
    private var _sent: [Sent] = []
    private var held: [String: Recorded] = [:]
    private var heldOrder: [String] = []

    /// Keep this task pending (it is still running in the OS) until `release`.
    var hold: @Sendable (String, Recorded) -> Bool = { _, _ in false }
    /// Fail the task with this error (e.g. a pinning rejection) before anything reaches the server.
    var errorFor: @Sendable (Recorded) -> Error? = { _ in nil }
    /// Fail the task with this error code before anything reaches the server.
    var failBeforeSending: @Sendable (Recorded) -> URLError.Code? = { _ in nil }
    /// Deliver the task to the server, then report this error code instead of its response.
    var loseResponse: @Sendable (Recorded) -> URLError.Code? = { _ in nil }

    init(restoring pending: [String: Recorded] = [:]) {
        held = pending
        heldOrder = Array(pending.keys)
    }

    func setCompletionHandler(_ handler: @escaping @Sendable (UploadCompletion) async -> Void) {
        lock.lockSync(); self.handler = handler; lock.unlockSync()
    }

    func enqueue(request: URLRequest, file: URL?, taskDescription: String) async throws {
        let body = try file.map { try Data(contentsOf: $0) } ?? Data()
        let rec = Recorded(method: request.httpMethod ?? "GET", url: request.url!,
                           headers: request.allHTTPHeaderFields ?? [:], body: body, timeout: request.timeoutInterval)
        let shouldHold = hold(taskDescription, rec)
        lock.lockSync()
        _sent.append(Sent(desc: taskDescription, request: rec, file: file))
        if shouldHold {
            held[taskDescription] = rec
            heldOrder.append(taskDescription)
        }
        lock.unlockSync()
        if shouldHold { return }
        Task { await self.deliver(taskDescription, rec) }
    }

    func pendingTaskDescriptions() async -> [String] {
        lock.lockSync(); defer { lock.unlockSync() }
        return heldOrder
    }

    /// Lets a held task run now; returns once its completion was handled.
    func release(_ desc: String) async {
        lock.lockSync()
        let rec = held.removeValue(forKey: desc)
        heldOrder.removeAll { $0 == desc }
        lock.unlockSync()
        if let rec { await deliver(desc, rec) }
    }

    var sent: [Sent] { lock.lockSync(); defer { lock.unlockSync() }; return _sent }
    var heldDescriptions: [String] { lock.lockSync(); defer { lock.unlockSync() }; return heldOrder }

    private func deliver(_ desc: String, _ rec: Recorded) async {
        lock.lockSync()
        let h = handler
        lock.unlockSync()
        let completion = answer(desc, rec)
        await h?(completion)
    }

    /// Lets a held task run once, then delivers its completion twice at the same time (a session
    /// that reports a task again, e.g. around a relaunch).
    func releaseTwice(_ desc: String) async {
        lock.lockSync()
        let rec = held.removeValue(forKey: desc)
        heldOrder.removeAll { $0 == desc }
        let h = handler
        lock.unlockSync()
        guard let rec, let h else { return }
        let completion = answer(desc, rec)
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await h(completion) }
            g.addTask { await h(completion) }
        }
    }

    private func answer(_ desc: String, _ rec: Recorded) -> UploadCompletion {
        let completion: UploadCompletion
        if let e = errorFor(rec) {
            completion = UploadCompletion(taskDescription: desc, status: nil, headers: [:], body: nil, error: e)
        } else if let code = failBeforeSending(rec) {
            completion = UploadCompletion(taskDescription: desc, status: nil, headers: [:], body: nil,
                                          error: URLError(code))
        } else {
            let reply = StubServer.shared.handle(rec)
            if let code = loseResponse(rec) {
                completion = UploadCompletion(taskDescription: desc, status: nil, headers: [:], body: nil,
                                              error: URLError(code))
            } else {
                switch reply {
                case let .error(code):
                    completion = UploadCompletion(taskDescription: desc, status: nil, headers: [:], body: nil,
                                                  error: URLError(code))
                case let .http(status, headers, data):
                    completion = UploadCompletion(taskDescription: desc, status: status, headers: headers,
                                                  body: data, error: nil)
                }
            }
        }
        return completion
    }
}

// MARK: - a small tus server

/// Enough of the server for pipeline tests (P§7.2–§7.4): check verdicts, tus create /
/// creation-with-upload / PATCH / HEAD with finalize, outcome #3 and #4, tombstones, Live Photo
/// pairing (H4) and token refresh. `override` answers a request first when it returns a reply.
final class MiniServer: @unchecked Sendable {
    struct Session {
        var sha: String
        var length: Int64
        var data: Data
        var meta: [String: String]
        var assetId: String?
    }

    private let lock = NSLock()
    private(set) var assets: [String: String] = [:] // sha -> asset id
    private var liveVideos: [String: String] = [:] // primary sha -> video sha
    private var tombstones: Set<String> = []
    private var sessions: [String: Session] = [:]
    private var nextId = 0
    private var refreshes = 0
    private var _creates: [[String: String]] = []
    var override: @Sendable (Recorded) -> StubReply? = { _ in nil }

    func install() {
        StubServer.shared.install { [self] r in self.handle(r) }
    }

    var creates: [[String: String]] { locked { _creates } }
    func assetId(_ sha: String) -> String? { locked { assets[sha] } }
    func addAsset(_ sha: String) { locked { assets[sha] = newId("asset") } }
    func tombstone(_ sha: String) { locked { _ = tombstones.insert(sha) } }
    func expireSessions() { locked { sessions.removeAll() } }
    func liveVideo(of sha: String) -> String? { locked { liveVideos[sha] } }
    var assetCount: Int { locked { assets.count } }

    func handle(_ r: Recorded) -> StubReply {
        if let o = override(r) { return o }
        return locked { route(r) }
    }

    private func route(_ r: Recorded) -> StubReply {
        switch (r.method, r.path) {
        case ("POST", "/api/v1/auth/refresh"):
            refreshes += 1
            return .json(200, tokensJSON(refreshes))
        case ("POST", "/api/v1/sync/check"):
            return check(r)
        case ("POST", "/api/v1/uploads"):
            return create(r)
        case (_, let p) where p.hasPrefix("/api/v1/uploads/"):
            let id = String(p.dropFirst("/api/v1/uploads/".count))
            switch r.method {
            case "HEAD": return head(id)
            case "PATCH": return patch(id, r)
            default: return .empty(405)
            }
        case ("DELETE", let p) where p.hasPrefix("/api/v1/tombstones/"):
            tombstones.remove(String(p.dropFirst("/api/v1/tombstones/".count)))
            return .empty(204)
        default:
            return .empty(404)
        }
    }

    private func check(_ r: Recorded) -> StubReply {
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: r.body),
              let items = body["items"]?.arrayValue else { return .problem(400, "invalid_request") }
        var results: [String] = []
        for it in items {
            let sha = it["sha256"]?.stringValue ?? ""
            if let id = assets[sha] {
                let live = liveVideos[sha] != nil
                results.append(#"{"sha256":"\#(sha)","verdict":"exists","asset_id":"\#(id)","asset_state":"active","has_live_video":\#(live),"on_disk":true}"#)
            } else if tombstones.contains(sha) {
                results.append(#"{"sha256":"\#(sha)","verdict":"tombstoned","deleted_at":"2026-10-01T00:00:00Z"}"#)
            } else if let (id, s) = sessions.first(where: { $0.value.sha == sha && $0.value.assetId == nil }) {
                results.append(#"{"sha256":"\#(sha)","verdict":"partial","upload":{"id":"\#(id)","url":"/api/v1/uploads/\#(id)","offset":\#(s.data.count),"length":\#(s.length)}}"#)
            } else {
                results.append(#"{"sha256":"\#(sha)","verdict":"missing"}"#)
            }
        }
        return .json(200, #"{"results":[\#(results.joined(separator: ","))]}"#)
    }

    private func create(_ r: Recorded) -> StubReply {
        let meta = metadata(r)
        _creates.append(meta)
        let sha = meta["sha256"] ?? ""
        let length = Int64(r.header("Upload-Length") ?? "") ?? -1
        if tombstones.contains(sha) { return .problem(409, "tombstoned") }
        if meta["pair_role"] == "live_video" {
            guard let p = meta["pair_sha256"], let primaryId = assets[p] else {
                return .problem(409, "pair_primary_missing")
            }
            if liveVideos[p] == sha {
                let id = newId("u")
                return .empty(201, ["Location": "/api/v1/uploads/\(id)", "Upload-Offset": "\(length)",
                                    "PicTunnel-Asset-Id": primaryId, "PicTunnel-Asset-Created": "false"])
            }
        }
        if let existing = assets[sha], meta["pair_role"] != "live_video" {
            let id = newId("u")
            sessions[id] = Session(sha: sha, length: length, data: Data(), meta: meta, assetId: existing)
            return .empty(201, ["Location": "/api/v1/uploads/\(id)", "Upload-Offset": "\(length)",
                                "PicTunnel-Asset-Id": existing, "PicTunnel-Asset-Created": "false"])
        }
        if let (id, s) = sessions.first(where: { $0.value.sha == sha && $0.value.assetId == nil }) {
            if s.length != length { return .problem(409, "length_mismatch") }
            if s.data.isEmpty, !r.body.isEmpty { return append(id, r.body, created: true) }
            return .empty(201, ["Location": "/api/v1/uploads/\(id)", "Upload-Offset": "\(s.data.count)"])
        }
        let id = newId("u")
        sessions[id] = Session(sha: sha, length: length, data: Data(), meta: meta)
        if !r.body.isEmpty { return append(id, r.body, created: true) }
        return .empty(201, ["Location": "/api/v1/uploads/\(id)", "Upload-Offset": "0"])
    }

    private func head(_ id: String) -> StubReply {
        guard let s = sessions[id] else { return .empty(404) }
        var h = ["Upload-Offset": "\(s.data.count)", "Upload-Length": "\(s.length)"]
        if let a = s.assetId { h["PicTunnel-Asset-Id"] = a }
        return .empty(200, h)
    }

    private func patch(_ id: String, _ r: Recorded) -> StubReply {
        guard let s = sessions[id] else { return .problem(404, "not_found") }
        let offset = Int64(r.header("Upload-Offset") ?? "") ?? -1
        if offset != Int64(s.data.count) {
            return .problem(409, "offset_mismatch", headers: ["Upload-Offset": "\(s.data.count)"])
        }
        return append(id, r.body, created: false)
    }

    private func append(_ id: String, _ bytes: Data, created: Bool) -> StubReply {
        guard var s = sessions[id] else { return .problem(404, "not_found") }
        s.data.append(bytes)
        var headers = ["Upload-Offset": "\(s.data.count)"]
        if created { headers["Location"] = "/api/v1/uploads/\(id)" }
        if Int64(s.data.count) == s.length {
            if sha256Hex(s.data) != s.sha {
                sessions[id] = nil
                return .problem(460, "checksum_mismatch")
            }
            let assetId: String
            if s.meta["pair_role"] == "live_video", let p = s.meta["pair_sha256"], let primary = assets[p] {
                liveVideos[p] = s.sha
                assetId = primary
            } else {
                assetId = assets[s.sha] ?? newId("asset")
                assets[s.sha] = assetId
            }
            s.assetId = assetId
            headers["PicTunnel-Asset-Id"] = assetId
            headers["PicTunnel-Asset-Created"] = "true"
        }
        sessions[id] = s
        return .empty(created ? 201 : 204, headers)
    }

    private func newId(_ prefix: String) -> String {
        nextId += 1
        return "\(prefix)\(nextId)"
    }

    private func metadata(_ r: Recorded) -> [String: String] {
        var out: [String: String] = [:]
        for pair in (r.header("Upload-Metadata") ?? "").split(separator: ",") {
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard let k = parts.first else { continue }
            let v = parts.count > 1 ? Data(base64Encoded: String(parts[1])).map { String(decoding: $0, as: UTF8.self) } : ""
            out[String(k)] = v ?? ""
        }
        return out
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lockSync()
        defer { lock.unlockSync() }
        return body()
    }
}

/// Polls `condition` (real time) until it holds or `timeout` passes.
func waitUntil(timeout: TimeInterval = 5, _ condition: () throws -> Bool) async rethrows -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return try condition()
}

func randomBytes(_ n: Int, seed: UInt8 = 7) -> Data {
    var g = SplitMix(seed: UInt64(seed) &+ UInt64(n))
    return Data((0..<n).map { _ in UInt8(truncatingIfNeeded: g.next()) })
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension NSLock {
    /// Short, non-suspending critical sections in test fakes that are called from async code.
    func lockSync() { lock() }
    func unlockSync() { unlock() }
}

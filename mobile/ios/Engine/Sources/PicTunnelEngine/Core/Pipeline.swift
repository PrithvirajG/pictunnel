import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// State shared by the phases of one run (or by one orphan completion).
final class RunCtx: @unchecked Sendable {
    fileprivate struct State {
        var stop: StopReason?
        var skipThisRun: Set<String> = []
        var freshOffset: Set<String> = []
        var inFlightSha: Set<String> = []
        var authRetries = 0
        var authRetryAtMs: Int64?
        var forcedNextAtMs: Int64?
        var transitions = 0
        var scanned = 0
        var hashed = 0
        var checked = 0
        var backedUp = 0
        var skipped = 0
        var needsAttention = 0
        var uploadsStarted = 0
    }

    private let lock = NSLock()
    private var s = State()
    private let budget: RunBudget
    private let clock: any Clock
    private let startMono: Int64

    init(budget: RunBudget, clock: any Clock) {
        self.budget = budget
        self.clock = clock
        startMono = clock.monotonicMs()
    }

    private func locked<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&s)
    }

    var stopReason: StopReason? { locked { $0.stop } }
    var stopped: Bool { locked { $0.stop != nil } }

    /// Records the first reason only; true when this call set it.
    @discardableResult
    func stop(_ r: StopReason) -> Bool {
        locked { s in
            guard s.stop == nil else { return false }
            s.stop = r
            return true
        }
    }

    func skip(_ id: String) { locked { _ = $0.skipThisRun.insert(id) } }
    var skipped: Set<String> { locked { $0.skipThisRun } }

    /// Offsets the server confirmed during this run; any other offset is confirmed by HEAD first (R2).
    func markFresh(_ id: String) { locked { _ = $0.freshOffset.insert(id) } }
    func unmarkFresh(_ id: String) { locked { _ = $0.freshOffset.remove(id) } }
    func isFresh(_ id: String) -> Bool { locked { $0.freshOffset.contains(id) } }

    /// Two phone items with the same bytes never upload at the same time.
    func claimSha(_ sha: String) -> Bool { locked { $0.inFlightSha.insert(sha).inserted } }
    func releaseSha(_ sha: String) { locked { _ = $0.inFlightSha.remove(sha) } }

    /// The next refresh retry (1-based), or nil once `maxAuthRetries` are spent.
    func nextAuthRetry(max: Int) -> Int? {
        locked { s in
            guard s.authRetries < max else { return nil }
            s.authRetries += 1
            return s.authRetries
        }
    }

    var authRetryAtMs: Int64? {
        get { locked { $0.authRetryAtMs } }
        set { locked { $0.authRetryAtMs = newValue } }
    }

    var forcedNextAtMs: Int64? {
        get { locked { $0.forcedNextAtMs } }
        set { locked { $0.forcedNextAtMs = newValue } }
    }

    func count(_ key: WritableKeyPath<Counters, Int>, _ n: Int = 1) {
        locked { s in
            var c = Counters(state: s)
            c[keyPath: key] += n
            c.write(to: &s)
        }
    }

    var counters: Counters { locked { Counters(state: $0) } }

    /// True (and the run stops) once the time budget is spent.
    func outOfTime() -> Bool {
        guard let max = budget.maxDurationMs else { return false }
        if clock.monotonicMs() - startMono < max { return false }
        stop(.budget)
        return true
    }

    /// True (and the run stops) when no further upload may start.
    func outOfUploads() -> Bool {
        guard let max = budget.maxUploads else { return false }
        if locked({ $0.uploadsStarted }) < max { return false }
        stop(.budget)
        return true
    }

    struct Counters {
        var transitions = 0, scanned = 0, hashed = 0, checked = 0, backedUp = 0, skipped = 0
        var needsAttention = 0, uploadsStarted = 0

        fileprivate init(state s: State) {
            transitions = s.transitions
            scanned = s.scanned
            hashed = s.hashed
            checked = s.checked
            backedUp = s.backedUp
            skipped = s.skipped
            needsAttention = s.needsAttention
            uploadsStarted = s.uploadsStarted
        }

        fileprivate func write(to s: inout State) {
            s.transitions = transitions
            s.scanned = scanned
            s.hashed = hashed
            s.checked = checked
            s.backedUp = backedUp
            s.skipped = skipped
            s.needsAttention = needsAttention
            s.uploadsStarted = uploadsStarted
        }
    }
}

/// What the caller of a step does next with the item.
enum Next { case go, stopItem, stopRun }

/// The backup pipeline (M§4.2, M§6): scan → hash (while exporting to staging) → check → upload.
/// Every item row is written before the network call it governs (R1), and every server response
/// goes through `Decide.decide`; the resulting `Decision` is applied by `apply` and nowhere else.
/// A `tls` transport (every endpoint refused the certificate) is not an item failure: it pauses
/// the run. Uploads carrying bytes go through the `BackgroundUploader`; HEAD and check are
/// foreground calls through `ServerClient`.
final class Pipeline: @unchecked Sendable {
    static let page = 250
    static let maxSteps = 64
    static let maxResolves = 2
    static let serverPauseMs: Int64 = 30 * 60 * 1000
    static let untrustedPauseMs: Int64 = 60 * 60 * 1000
    /// The longest server-caused pause; an expiry further ahead means the clock jumped back (R10).
    static let maxPauseMs: Int64 = max(serverPauseMs, untrustedPauseMs)
    /// Refresh retries after a transient failure: 2, 4 and 8 s, all inside the 30 s grace window.
    static let maxAuthRetries = 3
    static let authRetryCapMs: Int64 = 8000
    /// When the refresh keeps failing, the next run comes this soon (still inside the window).
    static let authRetryNextRunMs: Int64 = 5000
    static let activeStates: [ItemState] = [.discovered, .hashed, .queued, .uploading, .verifying]

    let db: EngineDB
    let library: any PhotoLibrary
    let uploader: any BackgroundUploader
    let client: ServerClient
    let settings: SettingsRepo
    let clock: any Clock
    let events: any EngineEvents
    let log: ActivityLog
    let reporter: StatusReporter
    let config: EngineConfig
    let tracker: UploadTracker

    init(db: EngineDB, library: any PhotoLibrary, uploader: any BackgroundUploader, client: ServerClient,
         settings: SettingsRepo, clock: any Clock, events: any EngineEvents, log: ActivityLog,
         reporter: StatusReporter, config: EngineConfig, tracker: UploadTracker) {
        self.db = db
        self.library = library
        self.uploader = uploader
        self.client = client
        self.settings = settings
        self.clock = clock
        self.events = events
        self.log = log
        self.reporter = reporter
        self.config = config
        self.tracker = tracker
    }

    // MARK: - staging (M§6)

    func stagedURL(_ itemId: String) -> URL {
        config.stagingDir.appendingPathComponent(EngineController.stagedName(itemId: itemId))
    }

    func chunkURL(_ itemId: String, offset: Int64) -> URL {
        config.stagingDir.appendingPathComponent("\(EngineController.stagedName(itemId: itemId)).\(offset).chunk")
    }

    /// Deletes the staged export of an item and any chunk slices cut from it.
    func removeStaged(_ itemId: String) {
        let fm = FileManager.default
        let name = EngineController.stagedName(itemId: itemId)
        try? fm.removeItem(at: config.stagingDir.appendingPathComponent(name))
        for f in (try? fm.contentsOfDirectory(atPath: config.stagingDir.path)) ?? []
        where f.hasPrefix(name + ".") && (f.hasSuffix(".chunk") || f.hasSuffix(".part")) {
            try? fm.removeItem(at: config.stagingDir.appendingPathComponent(f))
        }
    }

    private func stagedBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for f in (try? fm.contentsOfDirectory(atPath: config.stagingDir.path)) ?? [] {
            let attrs = try? fm.attributesOfItem(atPath: config.stagingDir.appendingPathComponent(f).path)
            total += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }

    /// Exports the resource to `<staging>/<name>.part`, then renames it into place.
    private func export(_ item: Item) async throws -> ExportedResource {
        let fm = FileManager.default
        try fm.createDirectory(at: config.stagingDir, withIntermediateDirectories: true)
        let target = stagedURL(item.localId)
        let part = target.appendingPathExtension("part")
        try? fm.removeItem(at: part)
        let ref = ItemRef(rowId: item.localId)
        var e = try await library.exportResource(assetLocalId: ref.assetLocalId, role: ref.role, to: part)
        try? fm.removeItem(at: target)
        do {
            try fm.moveItem(at: part, to: target)
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
        e.file = target
        return e
    }

    /// The staged file for an upload, exported again if it is gone. Nil (already handled) when the
    /// file cannot be read or its content changed since it was hashed.
    private func ensureStaged(_ ctx: RunCtx, _ item: Item) async -> URL? {
        let url = stagedURL(item.localId)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = (attrs?[.size] as? NSNumber)?.int64Value, size == item.size { return url }
        do {
            let e = try await export(item)
            if e.sha256 == item.sha256, e.size == item.size { return url }
            // Changed since it was hashed: new bytes, new identity. Hash again from the start.
            removeStaged(item.localId)
            try? db.deleteHashes(localIds: [item.localId])
            var next = item.cleared()
            next.state = .discovered
            next.sha256 = nil
            next.assetId = nil
            next.nextAttemptAtMs = nil
            save(ctx, item, next)
            return nil
        } catch {
            if Task.isCancelled || error is CancellationError {
                ctx.stop(.budget)
                return nil
            }
            let ref = ItemRef(rowId: item.localId)
            if await library.fingerprint(assetLocalId: ref.assetLocalId, role: ref.role) == nil {
                forget(item.localId)
            } else {
                localFailure(ctx, item, code: "read_failed", error)
            }
            return nil
        }
    }

    // MARK: - scan (M§4.2)

    static let scanScope = "library"

    func scan(_ ctx: RunCtx) async throws {
        let s = settings.get()
        let token = try db.scanToken(scope: Self.scanScope)
        let r = try await library.scan(since: token, settings: s)
        let resources = r.changed.filter { res in
            if res.role == .original, !s.keepUneditedOriginals { return false }
            if res.role != .liveVideo, res.kind == .video, !s.includeVideos { return false }
            return true
        }
        // H3: an edited asset whose unedited original is kept stacks both under its local identifier,
        // but only if the primary is (re)created with that key: a stack_key cannot be added to an
        // asset the server already has, so then the original goes up on its own, unstacked.
        let primaries = Dictionary(resources.filter { $0.role == .primary }.map { ($0.assetLocalId, $0) },
                                   uniquingKeysWith: { a, _ in a })
        var stackable: [String: Bool] = [:]
        for asset in Set(resources.filter { $0.role == .original }.map(\.assetLocalId)) {
            stackable[asset] = try Self.primaryTakesStackKey(try db.item(localId: asset), primaries[asset])
        }
        let live = Set(resources.filter { $0.role == .liveVideo }.map(\.assetLocalId))

        var writes: [Item] = []
        for res in resources {
            let id = ItemRef(assetLocalId: res.assetLocalId, role: res.role).rowId
            let canStack = stackable[res.assetLocalId] == true
            let stackKey: String? = switch res.role {
            case .liveVideo: nil
            case .original: canStack ? res.assetLocalId : nil
            case .primary: canStack ? res.assetLocalId : nil
            }
            if res.role == .original, !canStack, try db.item(localId: id) == nil {
                log.note(ActivityLog.info, "The unedited original of \(res.filename) is backed up unstacked: "
                    + "its edited version was already on the server", id)
            }
            let pairRole: PairRole = res.role == .liveVideo ? .liveVideo : .primary
            let pairLocalId: String? = switch res.role {
            case .liveVideo: res.assetLocalId
            case .primary: live.contains(res.assetLocalId) ? ItemRef(assetLocalId: res.assetLocalId, role: .liveVideo).rowId : nil
            case .original: nil
            }
            let existing = try db.item(localId: id)
            var next: Item
            if let existing, existing.size == res.size, existing.modifiedAtMs == res.modifiedAtMs {
                next = existing
                next.takenAtMs = res.takenAtMs
                next.mime = res.mime
                next.kind = res.kind
                next.filename = res.filename
                next.pairRole = pairRole
                next.pairLocalId = pairLocalId
                next.stackKey = stackKey
                next.width = res.width ?? existing.width
                next.height = res.height ?? existing.height
                next.durationMs = res.durationMs ?? existing.durationMs
            } else {
                // New, or edited on the phone: new bytes, new identity. Hash again; the old asset
                // stays on the server.
                if existing != nil { removeStaged(id) }
                next = Item(localId: id, size: res.size, modifiedAtMs: res.modifiedAtMs, takenAtMs: res.takenAtMs,
                            mime: res.mime, kind: res.kind, filename: res.filename, pairRole: pairRole,
                            pairLocalId: pairLocalId, stackKey: stackKey, width: res.width, height: res.height,
                            durationMs: res.durationMs)
            }
            if next != existing {
                if existing?.state != next.state { ctx.count(\.transitions) }
                writes.append(next)
            }
        }
        for start in stride(from: 0, to: writes.count, by: 500) {
            try db.upsertAll(Array(writes[start..<min(start + 500, writes.count)]))
        }

        // Deleted on the phone: dropped from the index only, never sent to the server (R8).
        var gone = Set<String>()
        if !r.removedAssets.isEmpty || r.fullRescan {
            let removed = Set(r.removedAssets)
            let seen = Set(resources.map { ItemRef(assetLocalId: $0.assetLocalId, role: $0.role).rowId })
            for id in try db.allIds() {
                if removed.contains(ItemRef(rowId: id).assetLocalId) || (r.fullRescan && !seen.contains(id)) {
                    gone.insert(id)
                }
            }
        }
        let goneList = Array(gone)
        for start in stride(from: 0, to: goneList.count, by: 500) {
            let batch = Array(goneList[start..<min(start + 500, goneList.count)])
            try db.delete(localIds: batch)
            batch.forEach(removeStaged)
        }
        try db.setScanToken(scope: Self.scanScope, token: r.token)
        ctx.count(\.scanned, r.changed.count)
    }

    /// Whether an asset's primary will carry the stack key: it is new, it changed (re-created as a
    /// new asset), it already has the key, or it was never created on the server.
    static func primaryTakesStackKey(_ existing: Item?, _ res: LibraryResource?) throws -> Bool {
        guard let existing else { return true }
        if let res, existing.size != res.size || existing.modifiedAtMs != res.modifiedAtMs { return true }
        if existing.stackKey != nil { return true }
        let created = existing.assetId != nil || existing.uploadUrl != nil
            || ![.discovered, .hashed, .queued].contains(existing.state)
        return !created
    }

    // MARK: - hash (R3, M§6)

    func hashPhase(_ ctx: RunCtx) async {
        var staged = stagedBytes()
        while !ctx.stopped {
            let page = due([.discovered], ctx, limit: Self.page)
            if page.isEmpty { return }
            for item in page {
                if Task.isCancelled { ctx.stop(.budget) }
                if ctx.stopped || ctx.outOfTime() { return }
                guard let added = await hashOne(ctx, item, stagedBytes: staged) else {
                    // Staging is full: hash more once uploads have drained it (a later pass or run).
                    return
                }
                staged += added
            }
        }
    }

    /// Hashes one item; returns the bytes it added to staging, or nil when staging is full.
    private func hashOne(_ ctx: RunCtx, _ item: Item, stagedBytes: Int64) async -> Int64? {
        let id = item.localId
        let ref = ItemRef(rowId: id)
        guard let fp = await library.fingerprint(assetLocalId: ref.assetLocalId, role: ref.role) else {
            forget(id)
            return 0
        }
        var next = item
        next.modifiedAtMs = fp.modifiedAtMs
        next.state = .hashed
        next.nextAttemptAtMs = nil
        next.lastError = nil
        var added: Int64 = 0
        if let cached = try? db.cachedHash(localId: id, modifiedAtMs: fp.modifiedAtMs, size: fp.size) {
            // The bytes were read once already: never re-read them for hashing (R3).
            next.sha256 = cached
            next.size = fp.size
        } else {
            if stagedBytes >= config.maxStagedBytes { return nil }
            do {
                let e = try await export(item)
                try db.putHash(localId: id, modifiedAtMs: fp.modifiedAtMs, size: fp.size, sha256: e.sha256)
                next.sha256 = e.sha256
                next.size = e.size
                added = e.size
            } catch {
                if Task.isCancelled || error is CancellationError {
                    ctx.stop(.budget)
                    return 0
                }
                localFailure(ctx, item, code: "read_failed", error)
                return 0
            }
        }
        save(ctx, item, next)
        ctx.count(\.hashed)
        return added
    }

    // MARK: - check (P§7.2)

    func checkPhase(_ ctx: RunCtx) async {
        while !ctx.stopped, !ctx.outOfTime() {
            let batch = Array(due([.hashed], ctx, limit: config.checkBatchSize).prefix(config.checkBatchSize))
            if batch.isEmpty { return }
            _ = await checkItems(ctx, batch)
        }
    }

    /// Checks 1..1000 hashed items and applies each verdict; returns each item's new row and what to do next.
    func checkItems(_ ctx: RunCtx, _ batch: [Item]) async -> [(Item, Next)] {
        let out = await client.check(batch.map { CheckItem(sha256: $0.sha256 ?? "", sizeBytes: $0.size, localId: $0.localId) })
        ctx.count(\.checked, batch.count)
        let raw = out.raw
        if raw.transport == .tls {
            untrusted(ctx)
            return batch.map { ($0, .stopRun) }
        }
        if case .fail(_, .refreshFailed) = out {
            let retry = await authRecovery(ctx, raw)
            return batch.map { ($0, retry ? .go : .stopRun) }
        }
        let results = out.value
        if let results, results.count != batch.count {
            // The answer does not line up with the question: leave the batch for a later run (R7).
            return batch.map { skip(ctx, $0, "check answered \(results.count) of \(batch.count) items") }
        }
        var res: [(Item, Next)] = []
        for (i, item) in batch.enumerated() {
            if ctx.stopped {
                res.append((item, .stopRun))
                continue
            }
            let one = results.map { $0[i].outcome(from: raw) } ?? raw
            let upload = results?[i].upload
            res.append(await outcome(ctx, item, .check, hasUploadId: nil, one, failure: nil) { it in
                guard let upload else { return it }
                ctx.markFresh(it.localId)
                var n = it
                n.uploadId = upload.id
                n.uploadUrl = upload.url
                n.uploadOffset = upload.offset
                return n
            })
        }
        return res
    }

    // MARK: - upload (P§7.3, M§6)

    func uploadPhase(_ ctx: RunCtx, concurrency: Int) async {
        if ctx.stopped { return }
        var eligible: [Item] = []
        for it in due([.queued, .uploading, .verifying], ctx, limit: Self.page * 4) where pairReady(it) {
            // The OS is still running a task for this item (after a relaunch or an earlier run).
            if await tracker.isInFlight(it.localId) { continue }
            eligible.append(it)
        }
        if eligible.isEmpty { return }
        let slots = min(max(concurrency, 1), EngineSettings.maxConcurrency)
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for item in eligible {
                if running >= slots {
                    await group.next()
                    running -= 1
                }
                if Task.isCancelled { ctx.stop(.budget) }
                if ctx.stopped || ctx.outOfTime() || ctx.outOfUploads() { break }
                // Identical bytes never go up twice at once: the later item waits (no attempt).
                let sha = item.sha256 ?? ""
                if !sha.isEmpty, !ctx.claimSha(sha) { continue }
                ctx.count(\.uploadsStarted)
                group.addTask {
                    await self.uploadItem(ctx, item)
                    if !sha.isEmpty { ctx.releaseSha(sha) }
                }
                running += 1
            }
        }
    }

    /// H4: a Live Photo's video goes up only after its primary still is backed up.
    private func pairReady(_ item: Item) -> Bool {
        guard item.pairRole == .liveVideo else { return true }
        guard let p = item.pairLocalId.flatMap({ try? db.item(localId: $0) }) else { return false }
        return (p.state == .backedUp || p.state == .freed) && p.sha256 != nil
    }

    private func uploadItem(_ ctx: RunCtx, _ listed: Item) async {
        // The row may have moved since the phase listed it (an orphan completion was applied
        // meanwhile), or a task for it may be running: act only on the current row.
        guard !(await tracker.isInFlight(listed.localId)),
              let start = try? db.item(localId: listed.localId),
              [.queued, .uploading, .verifying].contains(start.state),
              start.nextAttemptAtMs.map({ $0 <= clock.nowMs() || $0 > clock.nowMs() + EngineDB.maxBackoffMs }) ?? true
        else { return }
        var item = start
        reporter.uploadStarted(item)
        defer { reporter.uploadEnded(start.localId) }
        var resolves = 0
        for _ in 0..<Self.maxSteps {
            if ctx.stopped { return }
            let step: (Item, Next)
            switch item.state {
            case .queued:
                step = await create(ctx, item)
            case .uploading where item.uploadUrl == nil:
                step = await create(ctx, item)
            case .uploading where item.uploadOffset == nil || !ctx.isFresh(item.localId):
                // An offset not confirmed by the server in this run may be stale (R2): ask first.
                step = await head(ctx, item)
            case .uploading where item.uploadOffset! >= item.size:
                // Every byte is there but no asset id yet: finalize may still be running.
                // Resolve with check instead of PATCHing (P§7.4).
                var v = item
                v.state = .verifying
                step = (save(ctx, item, v), .go)
            case .uploading:
                step = await patch(ctx, item)
            case .verifying, .hashed:
                if resolves < Self.maxResolves {
                    resolves += 1
                    step = await checkItems(ctx, [item]).first ?? (item, .stopItem)
                } else {
                    // Still finalizing: look again later; not the item's fault, so no attempt.
                    step = (wait(ctx, item, delayMs: backoff(1)), .stopItem)
                }
            default:
                return
            }
            item = step.0
            if step.1 != .go { return }
        }
        _ = skip(ctx, item, "upload did not settle in \(Self.maxSteps) steps")
    }

    private func create(_ ctx: RunCtx, _ item: Item) async -> (Item, Next) {
        var primarySha: String?
        if item.pairRole == .liveVideo {
            guard let sha = item.pairLocalId.flatMap({ try? db.item(localId: $0) })?.sha256 else {
                return skip(ctx, item, "live video without its primary")
            }
            primarySha = sha
        }
        guard let sha = item.sha256 else { return skip(ctx, item, "not hashed") }
        // Single shot from the staged file up to the chunk size. No bytes when the server already has
        // the content: a known asset (H4 re-attach) or an identical item backed up meanwhile.
        let known = item.assetId != nil || ((try? db.items(sha256: sha)) ?? []).contains {
            $0.localId != item.localId && ($0.state == .backedUp || $0.state == .freed) && $0.assetId != nil
        }
        var file: URL?
        if !known, item.size <= config.chunkBytes {
            guard let staged = await ensureStaged(ctx, item) else { return (item, .stopItem) }
            file = staged
        }
        let meta = UploadMeta(
            sha256: sha, filename: item.filename, mime: item.mime, localId: item.localId,
            createdAt: Self.rfc3339(item.takenAtMs), modifiedAt: Self.rfc3339(item.modifiedAtMs),
            pairRole: primarySha != nil ? PairRole.liveVideo.rawValue : nil, pairSha256: primarySha,
            stackKey: item.stackKey)
        let base = client.endpoints.active
        let request = TusRequests.create(base: base, meta: meta, length: item.size, bodyFile: file)
        let desc = TaskDescription(itemId: item.localId, uploadId: "", offset: 0)
        guard case let .done(raw, failure) = await send(ctx, request, file: file, desc: desc) else {
            return (item, .stopItem)
        }
        return await createOutcome(ctx, item, raw, failure: failure, base: base)
    }

    func createOutcome(_ ctx: RunCtx, _ item: Item, _ raw: ServerOutcome, failure: NetFailure?, base: URL) async -> (Item, Next) {
        await outcome(ctx, item, .createUpload, hasUploadId: false, raw, failure: failure) { it in
            guard let c = TusCreated(raw, base: base) else { return it }
            ctx.markFresh(it.localId)
            var n = it
            n.uploadUrl = c.url.absoluteString
            n.uploadId = c.url.lastPathComponent
            n.uploadOffset = c.offset
            return n
        }
    }

    private func head(_ ctx: RunCtx, _ item: Item) async -> (Item, Next) {
        guard let url = sessionURL(item) else { return skip(ctx, item, "upload session on another server") }
        let out = await client.perform(TusRequests.head(url))
        let failure: NetFailure? = if case let .fail(_, f) = out { f } else { nil }
        return await outcome(ctx, item, .headUpload, hasUploadId: true, out.raw, failure: failure) { it in
            guard let h = TusHead(out.raw) else { return it }
            ctx.markFresh(it.localId)
            var n = it
            n.uploadOffset = h.offset
            return n
        }
    }

    private func patch(_ ctx: RunCtx, _ item: Item) async -> (Item, Next) {
        guard let url = sessionURL(item), let offset = item.uploadOffset else {
            return skip(ctx, item, "upload session on another server")
        }
        guard let (request, chunk, desc) = await preparePatch(ctx, item, url: url, offset: offset) else {
            return (item, .stopItem)
        }
        switch await send(ctx, request, file: chunk, desc: desc) {
        case .detached:
            // The task runs on in the session: keep its chunk file for it.
            return (item, .stopItem)
        case .notStarted:
            try? FileManager.default.removeItem(at: chunk)
            return (item, .stopItem)
        case let .done(raw, failure):
            try? FileManager.default.removeItem(at: chunk)
            return await patchOutcome(ctx, item, raw, failure: failure)
        }
    }

    /// Cuts the next chunk (M§6: only after the previous one was accepted) and builds its PATCH.
    private func preparePatch(_ ctx: RunCtx, _ item: Item, url: URL, offset: Int64) async -> (URLRequest, URL, TaskDescription)? {
        guard let staged = await ensureStaged(ctx, item) else { return nil }
        let chunk: URL
        do {
            chunk = try ChunkSlicer().slice(source: staged, offset: offset,
                                            length: min(config.chunkBytes, item.size - offset), into: config.stagingDir)
        } catch {
            localFailure(ctx, item, code: "read_failed", error)
            return nil
        }
        let desc = TaskDescription(itemId: item.localId, uploadId: item.uploadId ?? url.lastPathComponent, offset: offset)
        return (TusRequests.patch(url, offset: offset), chunk, desc)
    }

    func patchOutcome(_ ctx: RunCtx, _ item: Item, _ raw: ServerOutcome, failure: NetFailure?) async -> (Item, Next) {
        await outcome(ctx, item, .appendUpload, hasUploadId: true, raw, failure: failure) { it in
            guard let p = TusPatched(raw) else { return it }
            ctx.markFresh(it.localId)
            self.reporter.bytesSent(it.localId, offset: p.offset)
            var n = it
            n.uploadOffset = p.offset
            return n
        }
    }

    /// The stored session URL, moved to the active endpoint; nil for a foreign host.
    private func sessionURL(_ item: Item) -> URL? {
        guard let stored = item.uploadUrl, let path = client.endpoints.relativize(stored) else { return nil }
        return client.endpoints.resolve(path)
    }

    enum SendResult {
        case done(ServerOutcome, NetFailure?)
        /// The run stopped waiting (budget spent or cancelled); the task keeps running in the session.
        case detached
        /// The task could not be handed to the session.
        case notStarted
    }

    /// Sends a byte-carrying request through the uploader and waits for its completion. A `401`
    /// refreshes once (single-flight) and sends again. Cancelling the caller stops the wait, not
    /// the task: its completion is then applied as an orphan.
    private func send(_ ctx: RunCtx, _ request: URLRequest, file: URL?, desc: TaskDescription) async -> SendResult {
        var retried = false
        while true {
            let token: String
            do {
                token = try await client.auth.accessToken()
            } catch let AuthError.transient(raw) {
                return .done(raw, .refreshFailed)
            } catch {
                return .done(ServerClient.repairOutcome, .needsRepair)
            }
            let req = TusRequests.authorize(request, accessToken: token, clientHeader: client.http.clientHeader)
            await tracker.begin(desc, owned: true)
            do {
                try await uploader.enqueue(request: req, file: file, taskDescription: desc.description)
            } catch {
                await tracker.abandon(desc)
                log.note(ActivityLog.error, "Could not start an upload: \(error)")
                ctx.skip(desc.itemId)
                return .notStarted
            }
            let tracker = self.tracker
            let answer = await withTaskCancellationHandler {
                await tracker.wait(desc)
            } onCancel: {
                Task { await tracker.detach(desc) }
            }
            guard let raw = answer else {
                if Task.isCancelled { ctx.stop(.budget) }
                return .detached
            }
            if raw.status == 401, !retried, raw.problem?.code != "refresh_token_reused" {
                retried = true
                switch await client.auth.onUnauthorized(failedToken: token) {
                case .refreshed: continue
                case let .needsRepair(r): return .done(r ?? ServerClient.repairOutcome, .needsRepair)
                case let .transient(r): return .done(r, .refreshFailed)
                }
            }
            return .done(raw, nil)
        }
    }

    // MARK: - completions without a waiting run (M§6)

    /// Applies a completion nobody waits for: after a relaunch, or after the run that started the
    /// task ended. The caller holds the item's claim (`UploadTracker.complete` returned `.orphan`)
    /// until this returns, so no run acts on the item meanwhile. The row must still be where the
    /// task left it; otherwise the completion is stale and changes nothing. When the server
    /// confirmed a new offset and bytes remain, the next chunk goes out at once, so uploading
    /// continues while the app is in the background.
    func handleOrphan(_ desc: TaskDescription, _ raw: ServerOutcome) async {
        let ctx = RunCtx(budget: RunBudget(), clock: clock)
        let result: (Item, Next)
        let row = try? db.item(localId: desc.itemId)
        if desc.isCreate {
            guard let item = row, item.state == .queued || (item.state == .uploading && item.uploadUrl == nil) else { return }
            result = await createOutcome(ctx, item, raw, failure: nil, base: client.endpoints.active)
        } else {
            // This task is over: its chunk file goes, unless another task of the item still needs it.
            if !(await tracker.chunkInUse(itemId: desc.itemId, offset: desc.offset, except: desc.description)) {
                try? FileManager.default.removeItem(at: chunkURL(desc.itemId, offset: desc.offset))
            }
            guard let item = row, item.state == .uploading, item.uploadOffset == desc.offset,
                  (item.uploadId ?? "") == desc.uploadId else { return }
            result = await patchOutcome(ctx, item, raw, failure: nil)
        }
        let next = result.0
        guard result.1 == .go, next.state == .uploading, ctx.isFresh(next.localId),
              let offset = next.uploadOffset, offset < next.size else { return }
        // After a relaunch no request may have reached an endpoint yet, and the upload session does
        // not fall back: settle on one that answers first (R9). If none does, the next run HEADs.
        guard (try? await client.endpoints.ensureActiveReached(client.http)) != nil,
              let url = sessionURL(next) else { return }
        await continueInBackground(ctx, next, url: url, offset: offset)
    }

    private func continueInBackground(_ ctx: RunCtx, _ item: Item, url: URL, offset: Int64) async {
        guard let (request, chunk, desc) = await preparePatch(ctx, item, url: url, offset: offset) else { return }
        guard let token = try? await client.auth.accessToken() else {
            // The next run sends it (after a HEAD); no chunk file is left behind.
            try? FileManager.default.removeItem(at: chunk)
            return
        }
        let req = TusRequests.authorize(request, accessToken: token, clientHeader: client.http.clientHeader)
        await tracker.begin(desc, owned: false)
        do {
            try await uploader.enqueue(request: req, file: chunk, taskDescription: desc.description)
        } catch {
            await tracker.abandon(desc)
            try? FileManager.default.removeItem(at: chunk)
        }
    }

    // MARK: - decisions

    private func outcome(_ ctx: RunCtx, _ item: Item, _ lastAction: LastAction, hasUploadId: Bool?,
                         _ raw: ServerOutcome, failure: NetFailure?, ok: (Item) -> Item) async -> (Item, Next) {
        // Every endpoint refused the certificate: a connection-level problem, not this item's.
        if raw.transport == .tls {
            untrusted(ctx)
            return (item, .stopRun)
        }
        if failure == .refreshFailed {
            return (item, await authRecovery(ctx, raw) ? .go : .stopRun)
        }
        let given = Given(flow: .backup, itemState: item.state, lastAction: lastAction, item: ItemFlags(
            kind: item.pairRole == .liveVideo ? .video : item.kind, attempts: item.attempts, hasUploadId: hasUploadId))
        return apply(ctx, item, raw, Decide.decide(given, raw), ok)
    }

    /// Applies one `Decision` to `item`: the only place a server response changes an item.
    private func apply(_ ctx: RunCtx, _ item: Item, _ raw: ServerOutcome, _ d: Decision,
                       _ ok: (Item) -> Item) -> (Item, Next) {
        let id = item.localId
        let attempts = item.attempts + d.attemptsDelta
        let state = d.nextState ?? item.state
        let error = Self.errorOf(raw)
        switch d.action {
        case .markBackedUp:
            // R4: only with a server asset id (decide() guarantees one is present).
            let assetId = raw.header("PicTunnel-Asset-Id").flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.checkResult(raw)?["asset_id"]?.stringValue
            var n = item.cleared()
            n.state = .backedUp
            n.assetId = assetId
            n.attempts = 0
            n.nextAttemptAtMs = nil
            n.lastError = nil
            let saved = save(ctx, item, n)
            removeStaged(id)
            ctx.count(\.backedUp)
            log.note(ActivityLog.backedUp, "Backed up \(item.filename)", id)
            return (saved, .stopItem)
        case .queueUpload:
            var n = item.cleared()
            n.state = .queued
            n.attempts = attempts
            n.nextAttemptAtMs = nil
            return (save(ctx, item, n), .go)
        case .resumeUpload:
            var n = ok(item)
            n.state = .uploading
            n.attempts = attempts
            n.nextAttemptAtMs = nil
            return (save(ctx, item, n), .go)
        case .headThenResume:
            ctx.unmarkFresh(id)
            var n = item
            n.state = .uploading
            n.attempts = attempts
            n.uploadOffset = nil
            n.lastError = error
            return (save(ctx, item, n), .go)
        case .restartUpload:
            ctx.unmarkFresh(id)
            var n = item.cleared()
            n.state = .queued
            n.attempts = attempts
            n.lastError = error
            return (save(ctx, item, n), .go)
        case .checkThenResolve:
            ctx.unmarkFresh(id)
            var n = item.cleared()
            n.state = .hashed
            n.attempts = attempts
            n.lastError = error
            return (save(ctx, item, n), .go)
        case .markSkipped:
            var n = item.cleared()
            n.state = .skipped
            n.nextAttemptAtMs = nil
            n.lastError = error
            let saved = save(ctx, item, n)
            removeStaged(id)
            ctx.count(\.skipped)
            log.note(ActivityLog.skipped, "Skipped \(item.filename): deleted from the server earlier", id)
            return (saved, .stopItem)
        case .rehashAndRequeue:
            try? db.deleteHashes(localIds: [id])
            removeStaged(id)
            var n = item.cleared()
            n.state = .discovered
            n.sha256 = nil
            n.attempts = attempts
            n.lastError = error
            return (save(ctx, item, n), .stopItem)
        case .backoffRetry:
            // The next attempt confirms the offset with HEAD before any PATCH (R2).
            ctx.unmarkFresh(id)
            var n = item
            n.state = state
            n.attempts = attempts
            n.lastError = error
            return (wait(ctx, n, delayMs: backoff(attempts)), .stopItem)
        case .waitRetryAfter:
            ctx.unmarkFresh(id)
            let now = Date(timeIntervalSince1970: Double(clock.nowMs()) / 1000)
            let delay = raw.retryAfter(now: now).map { Int64($0 * 1000) } ?? backoff(attempts)
            var n = item
            n.state = state
            n.attempts = attempts
            n.lastError = error
            return (wait(ctx, n, delayMs: delay), .stopItem)
        case .waitForNetwork:
            // R5: no network is never an attempt; the row is unchanged.
            ctx.stop(.offline)
            return (item, .stopRun)
        case .requireRepair:
            requireRepair(ctx)
            return (item, .stopRun)
        case .pauseAllUploads:
            return pauseRun(ctx, item, .serverFull, forMs: Self.serverPauseMs, "The server is out of storage")
        case .notifyQuota:
            return pauseRun(ctx, item, .quota, forMs: Self.serverPauseMs, "Your storage quota on the server is full")
        case .promptUpdate:
            return pauseRun(ctx, item, .clientTooOld, forMs: nil, "The server needs a newer version of the app")
        case .markNeedsAttention:
            var n = item
            n.state = .needsAttention
            n.attempts = attempts
            n.nextAttemptAtMs = nil
            n.lastError = error
            let saved = save(ctx, item, n)
            removeStaged(id)
            ctx.count(\.needsAttention)
            log.note(ActivityLog.needsAttention, "\(item.filename) needs attention (\(error ?? "unknown"))", id)
            return (saved, .stopItem)
        case .uploadPrimaryFirst:
            // H4: the server lacks the still; upload it again, then this video.
            if let p = item.pairLocalId.flatMap({ try? db.item(localId: $0) }), p.state == .backedUp || p.state == .freed {
                var q = p.cleared()
                q.state = .queued
                q.assetId = nil
                save(ctx, p, q)
            }
            var n = item.cleared()
            n.state = .queued
            n.attempts = attempts
            n.lastError = error
            return (save(ctx, item, n), .stopItem)
        case .uploadLiveVideo:
            // The still exists but its paired video is missing (crash between the two uploads, H4).
            let assetId = Self.checkResult(raw)?["asset_id"]?.stringValue
            if let v = item.pairLocalId.flatMap({ try? db.item(localId: $0) }), v.pairRole == .liveVideo,
               v.state == .backedUp || v.state == .freed {
                var q = v.cleared()
                q.state = .queued
                save(ctx, v, q)
            }
            var n = item.cleared()
            n.state = .queued
            n.assetId = assetId
            n.attempts = attempts
            return (save(ctx, item, n), .go)
        case .refreshThenRetry:
            return skip(ctx, item, "still unauthorized after a token refresh")
        case .skipThisRun:
            return skip(ctx, item, "unexpected answer (\(error ?? "no detail"))")
        default:
            return skip(ctx, item, "unexpected decision \(d.action.rawValue)")
        }
    }

    /// A transient refresh failure (P§6.2): the server may have rotated the refresh token while the
    /// answer was lost. The old token works only within 30 s of that rotation, so the refresh is
    /// retried promptly (2, 4, 8 s), never after an item backoff, and never as an item attempt.
    /// True when the caller should repeat its request.
    func authRecovery(_ ctx: RunCtx, _ raw: ServerOutcome) async -> Bool {
        let d = Decide.decide(Given(flow: .auth, itemState: nil, lastAction: .refresh), raw)
        switch d.action {
        case .waitForNetwork:
            ctx.stop(.offline)
            return false
        case .promptUpdate:
            settings.setPauseQuietly(PauseState(reason: .clientTooOld, untilMs: nil))
            if ctx.stop(.paused) { log.note(ActivityLog.paused, "Backup paused: The server needs a newer version of the app") }
            return false
        case .requireRepair:
            requireRepair(ctx)
            return false
        default:
            guard let n = ctx.nextAuthRetry(max: Self.maxAuthRetries) else {
                ctx.authRetryAtMs = clock.nowMs() + Self.authRetryNextRunMs
                if ctx.stop(.authRetry) {
                    log.note(ActivityLog.error, "Signing in to the server failed (\(Self.errorOf(raw) ?? "unknown")); retrying shortly")
                }
                return false
            }
            let now = Date(timeIntervalSince1970: Double(clock.nowMs()) / 1000)
            let base: Int64 = 2000 << Int64(n - 1)
            let delay = min(raw.retryAfter(now: now).map { Int64($0 * 1000) } ?? base, Self.authRetryCapMs)
            await clock.sleep(ms: delay)
            return !ctx.stopped
        }
    }

    private func requireRepair(_ ctx: RunCtx) {
        if ctx.stop(.needsRepair) {
            log.note(ActivityLog.error, "This phone is no longer paired with the server — pair again")
            events.needsRepair()
        }
    }

    private func pauseRun(_ ctx: RunCtx, _ item: Item, _ reason: PauseReason, forMs: Int64?, _ message: String) -> (Item, Next) {
        // A run-level pause (M§4.3): the row keeps its resumable state, so resuming needs no rewrite.
        settings.setPauseQuietly(PauseState(reason: reason, untilMs: forMs.map { clock.nowMs() + $0 }))
        if ctx.stop(.paused) { log.note(ActivityLog.paused, "Backup paused: \(message)") }
        return (item, .stopRun)
    }

    func untrusted(_ ctx: RunCtx) {
        settings.setPauseQuietly(PauseState(reason: EngineController.untrustedPauseReason,
                                            untilMs: clock.nowMs() + Self.untrustedPauseMs))
        if ctx.stop(.serverUntrusted) {
            log.note(ActivityLog.error, "Backup paused: server certificate changed — pair again")
        }
    }

    @discardableResult
    private func skip(_ ctx: RunCtx, _ item: Item, _ why: String) -> (Item, Next) {
        ctx.skip(item.localId)
        log.note(ActivityLog.info, "Skipped \(item.filename) for now: \(why)", item.localId)
        return (item, .stopItem)
    }

    /// A local read failure (not a server response): counted like a retryable failure.
    private func localFailure(_ ctx: RunCtx, _ item: Item, code: String, _ error: Error) {
        let attempts = item.attempts + 1
        var n = item
        n.attempts = attempts
        n.lastError = code
        if attempts >= maxAttempts {
            n.state = .needsAttention
            n.nextAttemptAtMs = nil
            save(ctx, item, n)
            removeStaged(item.localId)
            ctx.count(\.needsAttention)
            log.note(ActivityLog.needsAttention, "\(item.filename) could not be read: \(error)", item.localId)
        } else {
            wait(ctx, n, delayMs: backoff(attempts))
        }
    }

    func forget(_ localId: String) {
        _ = try? db.delete(localIds: [localId])
        removeStaged(localId)
    }

    @discardableResult
    private func wait(_ ctx: RunCtx, _ item: Item, delayMs: Int64) -> Item {
        var n = item
        // R10: no wait is longer than the backoff cap (a longer Retry-After included), so a later
        // time can only mean the clock jumped back, and `due` treats it as due.
        n.nextAttemptAtMs = clock.nowMs() + min(max(delayMs, 0), EngineDB.maxBackoffMs)
        return save(ctx, item, n)
    }

    private func backoff(_ attempts: Int) -> Int64 {
        var rng = SystemRandomNumberGenerator()
        return Int64(backoffDelay(attempt: max(attempts, 1), rng: &rng) * 1000)
    }

    @discardableResult
    func save(_ ctx: RunCtx?, _ before: Item, _ after: Item) -> Item {
        do {
            try db.upsert(after)
        } catch {
            log.note(ActivityLog.error, "Saving \(after.localId) failed: \(error)", after.localId)
        }
        if before.state != after.state { ctx?.count(\.transitions) }
        events.itemChanged(after)
        reporter.publish()
        return after
    }

    func due(_ states: [ItemState], _ ctx: RunCtx, limit: Int) -> [Item] {
        // Keyset pages past the rows skipped this run, so skipped rows never hide due ones.
        let skipped = ctx.skipped
        let now = clock.nowMs()
        var out: [Item] = []
        var after: PageKey?
        while out.count < limit {
            guard let page = try? db.due(states, nowMs: now, after: after, limit: limit) else { break }
            for it in page where !skipped.contains(it.localId) && out.count < limit { out.append(it) }
            guard page.count == limit, let last = page.last else { break }
            after = PageKey(last)
        }
        return out
    }

    static func errorOf(_ raw: ServerOutcome) -> String? {
        raw.problem?.code ?? raw.transport?.rawValue ?? raw.status.map { "http_\($0)" }
    }

    static func checkResult(_ raw: ServerOutcome) -> JSONValue? {
        raw.body?["results"]?.arrayValue?.first
    }

    static func rfc3339(_ ms: Int64) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

extension Item {
    /// Without the tus session fields.
    func cleared() -> Item {
        var n = self
        n.uploadId = nil
        n.uploadUrl = nil
        n.uploadOffset = nil
        return n
    }
}

extension SettingsRepo {
    /// Pauses never fail the run that hits them.
    func setPauseQuietly(_ p: PauseState) { try? setPause(p) }
}

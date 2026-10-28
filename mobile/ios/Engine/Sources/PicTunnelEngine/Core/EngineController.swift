import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A FIFO async mutex: one pipeline run (or free-up) at a time.
actor AsyncLock {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

/// The iOS backup engine (M§4, M§6): one pipeline run at a time, the background-upload
/// completion mapping, plus the queries and user actions the bridge exposes (M§3). Platform
/// pieces come in through `library`, `uploader` and the `Deleter` passed to `freeUpSpace`.
public final class EngineController: @unchecked Sendable {
    /// The Pigeon `PauseReason` has no "server identity changed" value; a persistent pin mismatch
    /// pauses with the closest fit and an activity entry ("server certificate changed — pair again").
    public static let untrustedPauseReason: PauseReason = .permission

    private static let maxPage = 1000

    private let db: EngineDB
    private let library: any PhotoLibrary
    private let uploader: any BackgroundUploader
    private let client: ServerClient
    private let settings: SettingsRepo
    private let clock: any Clock
    private let events: any EngineEvents
    private let config: EngineConfig
    private let log: ActivityLog
    private let reporter: StatusReporter
    private let tracker = UploadTracker()
    private let pipeline: Pipeline
    private let runLock = AsyncLock()
    private let sweptLock = NSLock()
    private var swept = false

    public init(db: EngineDB, library: any PhotoLibrary, uploader: any BackgroundUploader, client: ServerClient,
                settings: SettingsRepo, clock: any Clock, events: any EngineEvents, config: EngineConfig) {
        self.db = db
        self.library = library
        self.uploader = uploader
        self.client = client
        self.settings = settings
        self.clock = clock
        self.events = events
        self.config = config
        log = ActivityLog(db: db, clock: clock)
        reporter = StatusReporter(db: db, settings: settings, clock: clock, events: events)
        pipeline = Pipeline(db: db, library: library, uploader: uploader, client: client, settings: settings,
                            clock: clock, events: events, log: log, reporter: reporter, config: config,
                            tracker: tracker)
        uploader.setCompletionHandler { [weak self] c in
            await self?.handleUploadCompletion(taskDescription: c.taskDescription, status: c.status,
                                               headers: c.headers, body: c.body, error: c.error)
        }
    }

    /// The staging file name of an item (M§6 `staging/<localId>-<role>`), safe for any file system.
    public static func stagedName(itemId: String) -> String {
        let ref = ItemRef(rowId: itemId)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var safe = String(ref.assetLocalId.map { allowed.contains($0) ? $0 : "_" })
        if safe != ref.assetLocalId {
            // Replaced characters could make two ids collide: keep them apart with a stable hash.
            var h = SHA256Stream()
            h.update(Data(ref.assetLocalId.utf8))
            safe += "_" + h.finalizeHex().prefix(8)
        }
        return "\(safe)-\(ref.role.rawValue)"
    }

    // MARK: - runs

    /// Scan → hash → check → upload until nothing is due, the budget runs out, or the run must stop
    /// (offline, paused, server untrusted, needs repair, auth retry). Passes repeat while they make
    /// progress, so an item can go from new to backed up in one run and a Live Photo video follows
    /// its still (H4). When the budget ends while the session still uploads, the run returns and
    /// the tasks' completions are applied as they arrive (`handleUploadCompletion`).
    public func runOnce(budget: RunBudget) async -> RunReport {
        await runLock.lock()
        let report = await run(budget)
        await runLock.unlock()
        return report
    }

    private func run(_ budget: RunBudget) async -> RunReport {
        let ctx = RunCtx(budget: budget, clock: clock)
        // After a relaunch the session may still run tasks for some items: never start them twice.
        await tracker.restore(await uploader.pendingTaskDescriptions())
        if markSwept() { await sweepStaging() }

        if let pause = settings.pause() {
            let now = clock.nowMs()
            if let until = pause.untilMs, now >= until || until > now + Pipeline.maxPauseMs {
                // A server-caused pause has expired (or its end is further away than any pause
                // lasts, so the clock jumped back, R10): try again.
                try? settings.clearPause()
            } else {
                ctx.stop(.paused)
                return report(ctx)
            }
        }
        do {
            try await pipeline.scan(ctx)
        } catch {
            // Keep going with the index we have; the next scan tries again.
            log.note(ActivityLog.error, "Scanning the library failed: \(error)")
        }
        reporter.publish()

        let tracker = self.tracker
        let watcher: Task<Void, Never>? = budget.maxDurationMs.map { ms in
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
                if Task.isCancelled { return }
                ctx.stop(.budget)
                await tracker.detachAll()
            }
        }
        let concurrency = settings.get().uploadConcurrency
        var exhausted = true
        for _ in 0..<config.maxPasses {
            if Task.isCancelled { ctx.stop(.budget) }
            if ctx.stopped { exhausted = false; break }
            let before = ctx.counters.transitions
            await pipeline.hashPhase(ctx)
            if ctx.stopped { exhausted = false; break }
            await pipeline.checkPhase(ctx)
            if ctx.stopped { exhausted = false; break }
            await pipeline.uploadPhase(ctx, concurrency: concurrency)
            if ctx.stopped || ctx.counters.transitions == before { exhausted = false; break }
        }
        watcher?.cancel()
        // Anything still uploading runs on in the session; its completion is applied when it comes.
        await tracker.detachAll()
        // Answers that came in for tasks this run stopped waiting for are applied now.
        for (key, raw) in await tracker.takeEarly() {
            await applyOrphan(key, raw)
        }
        if exhausted, !ctx.stopped, hasDueWork() {
            // The pass limit ran out with work due: the next run should come at once.
            ctx.stop(.budget)
            ctx.forcedNextAtMs = clock.nowMs()
        }
        try? settings.setLastRunAtMs(clock.nowMs())
        reporter.publish(force: true)
        return report(ctx)
    }

    private func markSwept() -> Bool {
        sweptLock.lock()
        defer { sweptLock.unlock() }
        if swept { return false }
        swept = true
        return true
    }

    private func hasDueWork() -> Bool {
        !((try? db.due(Pipeline.activeStates, nowMs: clock.nowMs(), limit: 1)) ?? []).isEmpty
    }

    private func report(_ ctx: RunCtx) -> RunReport {
        let c = ctx.counters
        var next = ctx.forcedNextAtMs ?? (try? db.nextAttemptAfter(Pipeline.activeStates, nowMs: clock.nowMs())) ?? nil
        if let auth = ctx.authRetryAtMs { next = min(next ?? auth, auth) }
        return RunReport(scanned: c.scanned, hashed: c.hashed, checked: c.checked, backedUp: c.backedUp,
                         skipped: c.skipped, needsAttention: c.needsAttention, stop: ctx.stopReason ?? .idle,
                         nextAttemptAtMs: next)
    }

    /// A finished upload task (M§6). The platform layer calls this for every completion of the
    /// background session, including those delivered after a relaunch; the description
    /// `"<itemId>|<uploadId>|<offset>"` maps it back to its item row. A completion that no longer
    /// matches the row (stale, foreign or malformed) changes nothing, and so does a second
    /// delivery of the same completion.
    ///
    /// `error` is classified like any engine request (`Transport.classify`). Hook for the
    /// background session (Task 14): report a certificate the pinning delegate refused as
    /// `TransportFailure(code:, sent: false, pinRejectedHost: host)`; it then classifies as `tls`
    /// and pauses backup ("server certificate changed") instead of counting an attempt.
    public func handleUploadCompletion(taskDescription: String, status: Int?, headers: [String: String],
                                       body: Data? = nil, error: Error?) async {
        let raw: ServerOutcome
        if let error {
            raw = ServerOutcome(error: error)
        } else if let status {
            let json = body.flatMap { $0.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: $0) }
            raw = ServerOutcome(status: status, headers: headers, body: json)
        } else {
            raw = ServerOutcome(transport: .reset)
        }
        guard await tracker.complete(taskDescription, raw) == .orphan else { return }
        await applyOrphan(taskDescription, raw)
    }

    /// Applies an orphan completion while the tracker holds the item's claim, then releases it.
    private func applyOrphan(_ key: String, _ raw: ServerOutcome) async {
        if let desc = TaskDescription(parsing: key) {
            await pipeline.handleOrphan(desc, raw)
        }
        await tracker.finishOrphan(key)
        reporter.publish()
    }

    /// The launch sweep (M§6): removes `*.part` files, chunk slices no running task needs, and
    /// staged exports of items that will not upload them.
    public func sweepStaging() async {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: config.stagingDir.path) else { return }
        let running = await tracker.allDescriptions().union(await uploader.pendingTaskDescriptions())
        let keepChunks = Set(running.compactMap(TaskDescription.init(parsing:)).map {
            "\(Self.stagedName(itemId: $0.itemId)).\($0.offset).chunk"
        })
        let active = Set(((try? db.items(in: [.hashed, .queued, .uploading, .verifying], limit: Int.max)) ?? [])
            .map { Self.stagedName(itemId: $0.localId) })
        for name in files {
            let remove: Bool
            if name.hasSuffix(".part") {
                remove = true
            } else if name.hasSuffix(".chunk") {
                remove = !keepChunks.contains(name)
            } else {
                remove = !active.contains(name)
            }
            if remove { try? fm.removeItem(at: config.stagingDir.appendingPathComponent(name)) }
        }
    }

    // MARK: - status and control

    public func status() async -> BackupStatus { reporter.snapshot() }

    /// Pauses every run until `start`.
    public func pause(_ reason: PauseReason) async {
        settings.setPauseQuietly(PauseState(reason: reason, untilMs: nil))
        log.note(ActivityLog.paused, "Backup paused (\(reason.rawValue))")
        reporter.publish(force: true)
    }

    /// Clears any pause, including one the server caused. The caller schedules the next run.
    public func start() async {
        try? settings.clearPause()
        reporter.publish(force: true)
    }

    /// Call on a network change: go back to the preferred, LAN-first endpoint (R9).
    public func onNetworkChanged() { client.onNetworkChanged() }

    public func getSettings() async -> EngineSettings { settings.get() }

    /// Saves the settings. A change of what is backed up (unedited originals, videos, albums)
    /// forgets the scan token, so the next scan reports the whole library again under the new scope.
    public func setSettings(_ s: EngineSettings) async throws {
        let old = settings.get()
        try settings.set(s)
        if old.keepUneditedOriginals != s.keepUneditedOriginals || old.includeVideos != s.includeVideos
            || old.allAlbums != s.allAlbums || Set(old.albumIds) != Set(s.albumIds) {
            try db.setScanToken(scope: Pipeline.scanScope, token: nil)
        }
    }

    // MARK: - phone index, attention, activity

    public enum ListError: Error { case badKey }

    /// The phone timeline: newest first by `(takenAtMs, localId)`, both descending; `afterKey` is
    /// the exclusive `"<takenAtMs>|<localId>"` of the previous page's last item.
    public func listPhoneItems(afterKey: String?, limit: Int) async throws -> PhoneItemPage {
        let n = min(max(limit, 1), Self.maxPage)
        var key: PageKey?
        if let afterKey {
            guard let k = PageKey(parsing: afterKey) else { throw ListError.badKey }
            key = k
        }
        let page = try db.phonePage(after: key, limit: n)
        return PhoneItemPage(items: page, nextKey: page.count == n ? page.last.map { PageKey($0).description } : nil)
    }

    public func listAttention() async throws -> [AttentionItem] {
        try db.items(in: [.needsAttention], limit: Self.maxPage).map {
            let code = $0.lastError ?? "unknown"
            return AttentionItem(localId: $0.localId, filename: $0.filename, code: code,
                                 message: Self.attentionMessage(code), attempts: $0.attempts)
        }
    }

    /// Puts needs-attention items back in the pipeline with a fresh attempt count.
    public func retry(_ localIds: [String]) async {
        for id in localIds {
            guard let it = try? db.item(localId: id), it.state == .needsAttention else { continue }
            var n = it
            n.state = it.uploadUrl != nil ? .uploading : it.sha256 != nil ? .hashed : .discovered
            n.attempts = 0
            n.nextAttemptAtMs = nil
            n.lastError = nil
            pipeline.save(nil, it, n)
        }
        reporter.publish(force: true)
    }

    public func listActivity(limit: Int) async throws -> [ActivityEntry] { try log.latest(limit: limit) }

    /// "Back up again" for tombstoned content (P§7.7): removes the server's tombstone, then sends the
    /// matching skipped items back to check. False when the server did not confirm.
    public func undoSkip(_ sha256: String) async -> Bool {
        let raw = await client.deleteTombstone(sha256)
        // 204 removed it; 404 means there was none left to remove.
        guard let s = raw.status, s == 204 || s == 200 || s == 404 else { return false }
        for it in (try? db.items(sha256: sha256)) ?? [] where it.state == .skipped {
            var n = it
            n.state = .hashed
            n.attempts = 0
            n.nextAttemptAtMs = nil
            n.lastError = nil
            pipeline.save(nil, it, n)
        }
        log.note(ActivityLog.info, "Backing up again content deleted from the server earlier")
        reporter.publish(force: true)
        return true
    }

    // MARK: - free up space (M§4.5, P§7.8)

    /// Deletes local originals that are safely on the server. Candidates are backed-up assets
    /// (`localIds`, or all when nil). Immediately before the delete request, every resource of the
    /// asset (still, Live Photo video, kept original) is re-checked with `confirm_on_disk` and its
    /// local fingerprint compared; the asset is freed only if all pass. `deleter` shows the OS
    /// dialog; only the assets it confirms become `Freed`, cancelled ones stay `BackedUp`.
    public func freeUpSpace(_ localIds: [String]?, deleter: any Deleter) async -> FreeUpResult {
        await runLock.lock()
        let result = await freeUp(localIds, deleter: deleter)
        await runLock.unlock()
        return result
    }

    private func freeUp(_ localIds: [String]?, deleter: any Deleter) async -> FreeUpResult {
        var skipped: [SkippedFree] = []
        var roots: [Item] = []
        if let localIds {
            for id in localIds {
                if let it = try? db.item(localId: ItemRef(rowId: id).assetLocalId) { roots.append(it) } else {
                    skipped.append(SkippedFree(localId: id, reason: "unknown"))
                }
            }
        } else {
            roots = ((try? db.items(in: [.backedUp], limit: Int.max)) ?? []).filter { !$0.localId.contains("#") }
        }
        var groups: [[Item]] = []
        var seen = Set<String>()
        for root in roots where seen.insert(root.localId).inserted {
            let parts = [ResourceRole.liveVideo, .original].compactMap {
                try? db.item(localId: ItemRef(assetLocalId: root.localId, role: $0).rowId)
            }
            let group = [root] + parts
            if group.contains(where: { $0.state != .backedUp || $0.sha256 == nil }) {
                skipped.append(SkippedFree(localId: root.localId, reason: "not_backed_up"))
                continue
            }
            groups.append(group)
        }

        var allowed: [[Item]] = []
        for batch in batchGroups(groups) {
            let flat = batch.flatMap { $0 }
            let out = await client.check(flat.map { CheckItem(sha256: $0.sha256!, sizeBytes: $0.size, localId: $0.localId) },
                                         confirmOnDisk: true)
            let raw = out.raw
            let results = out.value.flatMap { $0.count == flat.count ? $0 : nil }
            var i = 0
            for group in batch {
                let groupResults = results.map { Array($0[i..<(i + group.count)]) }
                i += group.count
                var changed = false
                for it in group where await fingerprintChanged(it) { changed = true }
                let one: ServerOutcome
                if let groupResults {
                    one = ServerOutcome(status: raw.status, headers: raw.headers,
                                        body: .object(["results": .array(groupResults.map(\.json))]))
                } else if case .fail = out {
                    one = raw
                } else {
                    // A 200 whose results do not line up: no usable answer, so no delete.
                    one = ServerOutcome(transport: .reset)
                }
                let root = group[0]
                let d = Decide.decide(Given(flow: .freeUpSpace, itemState: root.state, lastAction: .freeUpSpaceCheck,
                                            item: ItemFlags(kind: root.kind, fingerprintChanged: changed)), one)
                if d.action == .deleteLocalAllowed {
                    allowed.append(group)
                    continue
                }
                skipped.append(SkippedFree(localId: root.localId, reason: denyReason(changed, groupResults, raw)))
                guard let target = d.nextState, target != .backedUp else { continue }
                for it in group {
                    var n = it.cleared()
                    n.state = target
                    n.assetId = nil
                    n.attempts = 0
                    n.nextAttemptAtMs = nil
                    if target == .discovered {
                        n.sha256 = nil
                        try? db.deleteHashes(localIds: [it.localId])
                    }
                    pipeline.save(nil, it, n)
                }
            }
        }

        var freedCount = 0
        var freedBytes: Int64 = 0
        if !allowed.isEmpty {
            let confirmed = await deleter.delete(allowed.map { $0[0].localId })
            for group in allowed {
                guard confirmed.contains(group[0].localId) else {
                    skipped.append(SkippedFree(localId: group[0].localId, reason: "cancelled"))
                    continue
                }
                // Freed only after the user confirmed the OS dialog (M§4.5).
                for it in group {
                    var n = it
                    n.state = .freed
                    pipeline.save(nil, it, n)
                    freedBytes += it.size
                }
                freedCount += 1
            }
            if freedCount > 0 {
                log.note(ActivityLog.freed, "Freed \(freedCount) items (\(freedBytes) bytes) from this phone")
            }
        }
        reporter.publish(force: true)
        return FreeUpResult(freedCount: freedCount, freedBytes: freedBytes, skipped: skipped)
    }

    private func fingerprintChanged(_ it: Item) async -> Bool {
        let ref = ItemRef(rowId: it.localId)
        guard let fp = await library.fingerprint(assetLocalId: ref.assetLocalId, role: ref.role) else { return true }
        return fp.size != it.size || fp.modifiedAtMs != it.modifiedAtMs
    }

    private func denyReason(_ changed: Bool, _ results: [CheckResult]?, _ raw: ServerOutcome) -> String {
        if changed { return "fingerprint_changed" }
        guard let results else { return Pipeline.errorOf(raw) ?? "check_failed" }
        for r in results {
            if r.verdict != "exists" { return "server_\(r.verdict)" }
            if r.assetState != "active" { return "not_active_on_server" }
            if r.onDisk != true { return "not_on_server_disk" }
        }
        return "denied"
    }

    /// Groups packed into check batches of at most `checkBatchSize` hashes.
    private func batchGroups(_ groups: [[Item]]) -> [[[Item]]] {
        var out: [[[Item]]] = []
        var cur: [[Item]] = []
        var n = 0
        for g in groups {
            if n + g.count > config.checkBatchSize, !cur.isEmpty {
                out.append(cur)
                cur = []
                n = 0
            }
            cur.append(g)
            n += g.count
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func attentionMessage(_ code: String) -> String {
        switch code {
        case "file_too_large": "The file is larger than the server accepts."
        case "forbidden": "The server refused this file."
        case "invalid_request": "The server rejected the upload request."
        case "read_failed": "The file could not be read on this phone."
        case "checksum_mismatch", "length_mismatch": "The file kept changing while it was uploaded."
        default: "Backing up this item failed repeatedly (\(code))."
        }
    }
}

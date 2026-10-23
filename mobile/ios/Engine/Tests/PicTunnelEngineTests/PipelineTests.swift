import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PicTunnelEngine

/// The iOS engine controller (M§4, M§6) against fakes: a photo library, a background uploader
/// served by a small tus server, and the real network layer over the URLProtocol stub. Mirrors
/// the Kotlin `PipelineTest` (Task 8), plus the background-uploader mapping of M§6.
final class PipelineTests: XCTestCase {
    private let base = "https://pictunnel.test"
    private var dir: URL!
    private var db: EngineDB!
    private var library: FakeLibrary!
    private var uploader: FakeUploader!
    private var server: MiniServer!
    private var store: InMemoryCredentialStore!
    private let clock = FakeClock()
    private let events = RecordingEvents()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try EngineDB(path: dir.appendingPathComponent("engine.sqlite").path)
        library = FakeLibrary()
        uploader = FakeUploader()
        server = MiniServer()
        server.install()
        store = InMemoryCredentialStore(testCredentials([base]))
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private var staging: URL { dir.appendingPathComponent("staging") }

    private func controller(chunk: Int64 = 1000, checkBatch: Int = 1000, maxPasses: Int = 20,
                            uploader up: FakeUploader? = nil) -> EngineController {
        let endpoints = Endpoints(store.creds!.endpoints)
        let http = stubHTTP()
        let clock = self.clock
        let auth = AuthManager(store: store, http: http, endpoints: endpoints,
                               uptime: { TimeInterval(clock.monotonicMs()) / 1000 })
        let client = ServerClient(endpoints: endpoints, auth: auth, http: http)
        return EngineController(
            db: db, library: library, uploader: up ?? uploader, client: client, settings: SettingsRepo(db: db),
            clock: clock, events: events,
            config: EngineConfig(stagingDir: staging, chunkBytes: chunk, checkBatchSize: checkBatch, maxPasses: maxPasses)
        )
    }

    private func item(_ id: String) throws -> Item { try XCTUnwrap(try db.item(localId: id), id) }

    private var requests: [Recorded] { StubServer.shared.requests }

    private func lines() -> [String] {
        requests.map { r in
            r.method == "PATCH" ? "PATCH \(r.path) @\(r.header("Upload-Offset") ?? "?")" : "\(r.method) \(r.path)"
        }.filter { !$0.hasSuffix("/auth/refresh") }
    }

    private func stagedFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).sorted()
    }

    // MARK: - Task 8 parity

    func testFreshUploadToBackedUp() async throws {
        let b = randomBytes(600)
        library.put("a", b)
        let report = await controller().runOnce(budget: RunBudget())

        XCTAssertEqual(report.stop, .idle)
        XCTAssertEqual(report.backedUp, 1)
        let a = try item("a")
        XCTAssertEqual(a.state, .backedUp)
        XCTAssertEqual(a.sha256, sha256Hex(b))
        XCTAssertEqual(a.assetId, server.assetId(sha256Hex(b)))
        XCTAssertEqual(lines(), ["POST /api/v1/sync/check", "POST /api/v1/uploads"])
        // Single shot from the staged file, with the metadata of P§7.3.
        let post = try XCTUnwrap(uploader.sent.first)
        XCTAssertEqual(post.request.body, b)
        XCTAssertEqual(post.desc, "a||0")
        XCTAssertEqual(post.request.header("Authorization"), "Bearer pt_at_1")
        XCTAssertEqual(post.request.header("PicTunnel-Client"), clientHeaderValue)
        let meta = try XCTUnwrap(server.creates.first)
        XCTAssertEqual(meta["sha256"], sha256Hex(b))
        XCTAssertEqual(meta["local_id"], "a")
        XCTAssertEqual(meta["filename"], "a.jpg")
        XCTAssertNotNil(meta["created_at"])
        // Staging is deleted once the item is BackedUp.
        XCTAssertEqual(stagedFiles(), [])
        XCTAssertEqual(try db.latestActivity(limit: 1).first?.kind, ActivityLog.backedUp)
    }

    func testExistsVerdictNoUpload() async throws {
        let b = randomBytes(300)
        server.addAsset(sha256Hex(b))
        library.put("e", b)
        _ = await controller().runOnce(budget: RunBudget())
        XCTAssertEqual(try item("e").state, .backedUp)
        XCTAssertEqual(try item("e").assetId, server.assetId(sha256Hex(b)))
        XCTAssertTrue(uploader.sent.isEmpty)
        XCTAssertEqual(stagedFiles(), [])
    }

    func testPartialVerdictResumes() async throws {
        let b = randomBytes(2500)
        library.put("p", b)
        // Another device started this content: the server holds a session with 1000 bytes.
        let created = server.handle(Recorded(
            method: "POST", url: URL(string: base + "/api/v1/uploads")!,
            headers: ["Upload-Length": "2500",
                      "Upload-Metadata": "sha256 \(Data(sha256Hex(b).utf8).base64EncodedString()),filename eA==,mime eA=="],
            body: b.prefix(1000), timeout: 60))
        guard case let .http(201, h, _) = created else { return XCTFail("\(created)") }
        let session = try XCTUnwrap(h["Location"])

        _ = await controller().runOnce(budget: RunBudget())
        XCTAssertEqual(try item("p").state, .backedUp)
        XCTAssertEqual(lines(), ["POST /api/v1/sync/check", "PATCH \(session) @1000", "PATCH \(session) @2000"])
        XCTAssertEqual(server.assetCount, 1)
    }

    func testTombstonedSkipped() async throws {
        let b = randomBytes(200)
        server.tombstone(sha256Hex(b))
        library.put("t", b)
        let report = await controller().runOnce(budget: RunBudget())
        XCTAssertEqual(try item("t").state, .skipped)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertTrue(uploader.sent.isEmpty)
        XCTAssertEqual(stagedFiles(), [])
    }

    func testTimeoutWithUploadIdHeads() async throws {
        let b = randomBytes(2500)
        library.put("h", b)
        let n = Counter()
        uploader.failBeforeSending = { r in r.method == "PATCH" && n.next() == 2 ? .timedOut : nil }
        _ = await controller().runOnce(budget: RunBudget())
        let h = try item("h")
        XCTAssertEqual(h.state, .backedUp)
        XCTAssertEqual(h.attempts, 0)
        let l = lines()
        let head = try XCTUnwrap(l.firstIndex { $0.hasPrefix("HEAD ") }, "\(l)")
        XCTAssertTrue(l[head - 1].hasPrefix("PATCH") && l[head - 1].hasSuffix("@0"), "\(l)")
        XCTAssertEqual(l.filter { $0.hasPrefix("PATCH") }.map { $0.components(separatedBy: "@").last! },
                       ["0", "1000", "2000"])
        XCTAssertEqual(l.filter { $0 == "POST /api/v1/uploads" }.count, 1)
    }

    func testTimeoutWithoutUploadIdChecks() async throws {
        let b = randomBytes(500)
        library.put("c", b)
        let n = Counter()
        uploader.failBeforeSending = { r in r.method == "POST" && n.next() == 1 ? .timedOut : nil }
        _ = await controller().runOnce(budget: RunBudget())
        XCTAssertEqual(try item("c").state, .backedUp)
        // POST timed out (unknown outcome, no session id): check before acting (R2).
        XCTAssertEqual(uploader.sent.map(\.request.method), ["POST", "POST"])
        XCTAssertEqual(lines(), ["POST /api/v1/sync/check", "POST /api/v1/sync/check", "POST /api/v1/uploads"])
    }

    func testTenFailuresNeedsAttention() async throws {
        library.put("f", randomBytes(400))
        server.override = { r in r.method == "POST" && r.path == "/api/v1/uploads" ? .problem(500, "internal") : nil }
        let c = controller()
        for run in 1...10 {
            _ = await c.runOnce(budget: RunBudget())
            let f = try item("f")
            if run < 10 {
                XCTAssertEqual(f.attempts, run)
                XCTAssertEqual(f.state, .queued)
                XCTAssertNotNil(f.nextAttemptAtMs)
            }
            clock.advance(60 * 60 * 1000)
        }
        let f = try item("f")
        XCTAssertEqual(f.state, .needsAttention)
        XCTAssertEqual(f.attempts, 10)
        XCTAssertEqual(f.lastError, "internal")
        XCTAssertEqual(stagedFiles(), [])
        let attention = try await c.listAttention()
        XCTAssertEqual(attention.map(\.localId), ["f"])
    }

    func testOfflineDoesNotCountAttempt() async throws {
        library.put("o", randomBytes(300))
        server.override = { _ in .error(.notConnectedToInternet) }
        let report = await controller().runOnce(budget: RunBudget())
        XCTAssertEqual(report.stop, .offline)
        let o = try item("o")
        XCTAssertEqual(o.state, .hashed)
        XCTAssertEqual(o.attempts, 0)
        XCTAssertNil(o.nextAttemptAtMs)
    }

    func testInsufficientStoragePausesAll() async throws {
        library.put("s1", randomBytes(300), takenAtMs: 2)
        library.put("s2", randomBytes(301), takenAtMs: 1)
        server.override = { r in
            r.method == "POST" && r.path == "/api/v1/uploads" ? .problem(507, "insufficient_storage") : nil
        }
        let c = controller(chunk: 1000)
        let report = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(report.stop, .paused)
        // The pause is run-level: rows keep their resumable state, never `Paused`.
        for id in ["s1", "s2"] {
            XCTAssertEqual(try item(id).state, .queued)
            XCTAssertEqual(try item(id).attempts, 0)
        }
        let status = await c.status()
        XCTAssertTrue(status.paused)
        XCTAssertEqual(status.pauseReason, .serverFull)

        let before = requests.count
        let again = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(again.stop, .paused)
        XCTAssertEqual(requests.count, before)

        // A server-caused pause is retried after it expires.
        server.override = { _ in nil }
        clock.advance(31 * 60 * 1000)
        _ = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(try item("s1").state, .backedUp)
        XCTAssertEqual(try item("s2").state, .backedUp)
    }

    func testHashingResumesFromCache() async throws {
        for i in 1...6 {
            let b = randomBytes(100 + i)
            library.put("k\(i)", b, takenAtMs: Int64(100 - i))
            server.addAsset(sha256Hex(b))
        }
        // The run is killed while exporting the 4th resource.
        let killer = KillSwitch()
        library.onExport = { n, _ in
            if n == 4 {
                killer.fire()
                throw CancellationError()
            }
        }
        let c1 = controller()
        let run = Task { await c1.runOnce(budget: RunBudget()) }
        killer.set(run)
        _ = await run.value
        XCTAssertEqual(library.exports.count, 4)
        let hashed = try db.items(in: [.hashed, .backedUp], limit: 10).map(\.localId)
        XCTAssertEqual(hashed.count, 3, "\(hashed)")
        // A hashed row is lost (e.g. never committed) while its cache entry stays.
        var lost = try item(hashed[0])
        lost.state = .discovered
        lost.sha256 = nil
        try db.upsert(lost)

        library.onExport = { _, _ in }
        _ = await controller().runOnce(budget: RunBudget())
        // Only the three never-hashed resources are read again (R3).
        XCTAssertEqual(library.exports.count, 4 + 3, "\(library.exports)")
        for i in 1...6 { XCTAssertEqual(try item("k\(i)").state, .backedUp) }
    }

    func testLivePhotoPrimaryFirst() async throws {
        let still = randomBytes(400, seed: 1)
        let video = randomBytes(700, seed: 2)
        library.putLive("L", still: still, video: video)
        // The server is slow to answer the still.
        uploader.hold = { desc, _ in desc.hasPrefix("L|") }
        let c = controller()
        let run = Task { await c.runOnce(budget: RunBudget()) }
        let stillSent = await waitUntil { self.uploader.heldDescriptions == ["L||0"] }
        XCTAssertTrue(stillSent)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(uploader.sent.count, 1, "the video waits for the still's answer")
        uploader.hold = { _, _ in false }
        await uploader.release("L||0")
        _ = await run.value

        XCTAssertEqual(try item("L").state, .backedUp)
        XCTAssertEqual(try item("L").kind, .livePhoto)
        let v = try item(ItemRef(assetLocalId: "L", role: .liveVideo).rowId)
        XCTAssertEqual(v.state, .backedUp)
        XCTAssertEqual(v.pairRole, .liveVideo)
        XCTAssertEqual(v.pairLocalId, "L")
        XCTAssertEqual(server.creates.count, 2)
        XCTAssertEqual(server.creates[0]["sha256"], sha256Hex(still))
        XCTAssertEqual(server.creates[1]["sha256"], sha256Hex(video))
        XCTAssertEqual(server.creates[1]["pair_role"], "live_video")
        XCTAssertEqual(server.creates[1]["pair_sha256"], sha256Hex(still))
        XCTAssertEqual(server.liveVideo(of: sha256Hex(still)), sha256Hex(video))
        // The phone index shows the asset once.
        let page = try await c.listPhoneItems(afterKey: nil, limit: 10)
        XCTAssertEqual(page.items.map(\.localId), ["L"])
    }

    func testPinMismatchPausesWithoutBurningAttempts() async throws {
        library.put("x", randomBytes(300))
        server.override = { _ in .error(.serverCertificateUntrusted) }
        let c = controller()
        let report = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(report.stop, .serverUntrusted)
        XCTAssertEqual(try item("x").attempts, 0)
        XCTAssertEqual(try item("x").state, .hashed)
        let status = await c.status()
        XCTAssertEqual(status.pauseReason, EngineController.untrustedPauseReason)
        XCTAssertEqual(events.repairs, 0)
        let log = try db.latestActivity(limit: 5).map(\.message)
        XCTAssertTrue(log.contains { $0.contains("server certificate changed — pair again") }, "\(log)")
    }

    func testHeadFinalizingResolvesViaCheck() async throws {
        let b = randomBytes(2000)
        library.put("v", b)
        // The last PATCH reaches the server, but its answer is lost.
        uploader.loseResponse = { r in r.method == "PATCH" && r.header("Upload-Offset") == "1000" ? .networkConnectionLost : nil }
        // Finalize still running: HEAD shows every byte but no asset id yet.
        server.override = { r in
            r.method == "HEAD" ? .empty(200, ["Upload-Offset": "2000", "Upload-Length": "2000"]) : nil
        }
        _ = await controller().runOnce(budget: RunBudget())
        let v = try item("v")
        XCTAssertEqual(v.state, .backedUp)
        XCTAssertEqual(v.assetId, server.assetId(sha256Hex(b)))
        let l = lines()
        XCTAssertEqual(l.filter { $0.hasPrefix("PATCH") }.count, 2, "never re-PATCHed: \(l)")
        XCTAssertEqual(l.last, "POST /api/v1/sync/check", "\(l)")
    }

    func testHead404RestartsWithPost() async throws {
        let b = randomBytes(2500)
        library.put("r", b)
        // The session expires while the second chunk is in flight; the drop leaves the outcome unknown.
        let server = self.server!
        let once = Counter()
        uploader.failBeforeSending = { r in
            guard r.method == "PATCH", r.header("Upload-Offset") == "1000", once.next() == 1 else { return nil }
            server.expireSessions()
            return .networkConnectionLost
        }
        let c = controller()
        _ = await c.runOnce(budget: RunBudget())
        let l = lines()
        XCTAssertEqual(try item("r").state, .backedUp, "\(l)")
        let head = try XCTUnwrap(l.firstIndex { $0.hasPrefix("HEAD") }, "\(l)")
        XCTAssertEqual(l.filter { $0 == "POST /api/v1/uploads" }.count, 2, "\(l)")
        XCTAssertGreaterThan(try XCTUnwrap(l.lastIndex(of: "POST /api/v1/uploads")), head)
        XCTAssertEqual(server.assetCount, 1)
    }

    func testDecideHeadNotFoundWithoutBodyRestarts() {
        let d = Decide.decide(
            Given(flow: .backup, itemState: .uploading, lastAction: .headUpload, item: ItemFlags(hasUploadId: true)),
            ServerOutcome(status: 404))
        XCTAssertEqual(d, Decision(nextState: .queued, action: .restartUpload, attemptsDelta: 0))
    }

    func testFreeUpSpaceAppliesFreedOnlyAfterConfirmation() async throws {
        let b1 = randomBytes(300, seed: 1), b2 = randomBytes(301, seed: 2), b3 = randomBytes(302, seed: 3)
        library.put("f1", b1)
        library.put("f2", b2)
        library.put("f3", b3)
        let c = controller()
        _ = await c.runOnce(budget: RunBudget())
        // f3's original is no longer on the server's disk.
        server.override = { r in
            guard r.path == "/api/v1/sync/check", String(decoding: r.body, as: UTF8.self).contains("confirm_on_disk\":true")
            else { return nil }
            let body = try! JSONDecoder().decode(JSONValue.self, from: r.body)
            let results = body["items"]!.arrayValue!.map { it -> String in
                let sha = it["sha256"]!.stringValue!
                let onDisk = sha != sha256Hex(b3)
                return #"{"sha256":"\#(sha)","verdict":"exists","asset_id":"x","asset_state":"active","has_live_video":false,"on_disk":\#(onDisk)}"#
            }
            return .json(200, #"{"results":[\#(results.joined(separator: ","))]}"#)
        }
        // The user confirms f1 only.
        let deleter = FakeDeleter { ids in Set(ids.filter { $0 == "f1" }) }
        let result = await c.freeUpSpace(nil, deleter: deleter)
        XCTAssertEqual(deleter.calls.map { $0.sorted() }, [["f1", "f2"]])
        XCTAssertEqual(result.freedCount, 1)
        XCTAssertEqual(result.freedBytes, 300)
        XCTAssertEqual(try item("f1").state, .freed)
        XCTAssertEqual(try item("f2").state, .backedUp)
        XCTAssertEqual(try item("f3").state, .backedUp)
        let reasons = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.localId, $0.reason) })
        XCTAssertEqual(reasons["f2"], "cancelled")
        XCTAssertEqual(reasons["f3"], "not_on_server_disk")
    }

    func testFreeUpSpaceRefusesChangedFile() async throws {
        library.put("m", randomBytes(300))
        let c = controller()
        _ = await c.runOnce(budget: RunBudget())
        library.put("m", randomBytes(300), modifiedAtMs: 999)
        let deleter = FakeDeleter()
        let result = await c.freeUpSpace(["m"], deleter: deleter)
        XCTAssertTrue(deleter.calls.isEmpty)
        XCTAssertEqual(result.skipped.map(\.reason), ["fingerprint_changed"])
        let m = try item("m")
        XCTAssertEqual(m.state, .discovered)
        XCTAssertNil(m.sha256)
        XCTAssertNil(m.assetId)
    }

    func testFreeUpRequeueClearsAssetAndUploadFields() async throws {
        let b = randomBytes(300)
        library.put("q", b)
        let c = controller()
        _ = await c.runOnce(budget: RunBudget())
        server.override = { r in
            r.path == "/api/v1/sync/check" ? .json(200, #"{"results":[{"sha256":"\#(sha256Hex(b))","verdict":"missing"}]}"#) : nil
        }
        let result = await c.freeUpSpace(["q"], deleter: FakeDeleter())
        XCTAssertEqual(result.freedCount, 0)
        let q = try item("q")
        XCTAssertEqual(q.state, .queued)
        XCTAssertNil(q.assetId)
        XCTAssertNil(q.uploadUrl)
        XCTAssertNil(q.uploadId)
        XCTAssertNil(q.uploadOffset)
    }

    func testPhoneItemsPageByTakenAtThenLocalId() async throws {
        try db.upsertAll([
            Item(localId: "a", size: 1, modifiedAtMs: 1, takenAtMs: 100, mime: "image/jpeg", kind: .photo, filename: "a"),
            Item(localId: "b", size: 1, modifiedAtMs: 1, takenAtMs: 200, mime: "image/jpeg", kind: .photo, filename: "b"),
            Item(localId: "c", size: 1, modifiedAtMs: 1, takenAtMs: 200, mime: "image/jpeg", kind: .livePhoto, filename: "c"),
            Item(localId: "c#live", size: 1, modifiedAtMs: 1, takenAtMs: 200, mime: "video/quicktime", kind: .video,
                 filename: "c", pairRole: .liveVideo, pairLocalId: "c"),
            Item(localId: "b#original", size: 1, modifiedAtMs: 1, takenAtMs: 200, mime: "image/jpeg", kind: .photo,
                 filename: "b", stackKey: "b"),
            Item(localId: "d", size: 1, modifiedAtMs: 1, takenAtMs: 50, mime: "image/jpeg", kind: .photo, filename: "d"),
        ])
        let c = controller()
        let first = try await c.listPhoneItems(afterKey: nil, limit: 2)
        XCTAssertEqual(first.items.map(\.localId), ["c", "b"])
        XCTAssertEqual(first.nextKey, "200|b")
        let second = try await c.listPhoneItems(afterKey: first.nextKey, limit: 2)
        XCTAssertEqual(second.items.map(\.localId), ["a", "d"])
        let last = try await c.listPhoneItems(afterKey: "100|a", limit: 2)
        XCTAssertEqual(last.items.map(\.localId), ["d"])
        XCTAssertNil(last.nextKey)
    }

    func testCheckBatchesAreBounded() async throws {
        for i in 1...5 { library.put("b\(i)", randomBytes(100 + i)) }
        _ = await controller(checkBatch: 2).runOnce(budget: RunBudget())
        let checks = requests.filter { $0.path == "/api/v1/sync/check" }
        let sizes = try checks.map { try JSONDecoder().decode(JSONValue.self, from: $0.body)["items"]!.arrayValue!.count }
        XCTAssertEqual(Array(sizes.prefix(3)), [2, 2, 1])
        XCTAssertTrue(sizes.allSatisfy { $0 <= 2 })
    }

    func testActivityLogIsARingOf1000() async throws {
        let log = ActivityLog(db: db, clock: clock)
        for i in 0..<1005 { try log.add(kind: ActivityLog.info, message: "m\(i)") }
        let all = try log.latest(limit: 5000)
        XCTAssertEqual(all.count, 1000)
        XCTAssertEqual(all.first?.message, "m1004")
        XCTAssertEqual(all.last?.message, "m5")
    }

    // MARK: - M§6 background uploader

    func testChunkedViaBackgroundUploaderCompletionMapping() async throws {
        let b = randomBytes(2500)
        library.put("big", b)
        let c = controller(chunk: 1000)
        _ = await c.runOnce(budget: RunBudget())

        let big = try item("big")
        XCTAssertEqual(big.state, .backedUp)
        let sent = uploader.sent
        XCTAssertEqual(sent.map(\.request.method), ["POST", "PATCH", "PATCH", "PATCH"])
        let uploadId = try XCTUnwrap(sent[1].request.url.lastPathComponent)
        // taskDescription = "<itemId>|<uploadId>|<offset>" (M§6).
        XCTAssertEqual(sent.map(\.desc), ["big||0", "big|\(uploadId)|0", "big|\(uploadId)|1000", "big|\(uploadId)|2000"])
        XCTAssertTrue(sent[0].request.body.isEmpty, "bodyless create above the single-shot limit")
        XCTAssertEqual(sent[0].request.header("Upload-Length"), "2500")
        // Each chunk is its own file with exactly that slice.
        XCTAssertEqual(sent[1].request.body, b.subdata(in: 0..<1000))
        XCTAssertEqual(sent[2].request.body, b.subdata(in: 1000..<2000))
        XCTAssertEqual(sent[3].request.body, b.subdata(in: 2000..<2500))
        XCTAssertTrue(sent[1...].allSatisfy { $0.file?.lastPathComponent.hasSuffix(".chunk") == true })
        XCTAssertTrue(sent[1...].allSatisfy { $0.request.header("Content-Type") == "application/offset+octet-stream" })
        XCTAssertEqual(stagedFiles(), [], "chunk files and staging are removed")

        // A completion that no longer matches the row (stale or foreign) changes nothing.
        await c.handleUploadCompletion(taskDescription: "big|\(uploadId)|1000", status: 204,
                                       headers: ["Upload-Offset": "2000"], error: nil)
        await c.handleUploadCompletion(taskDescription: "nobody|u9|0", status: 204, headers: [:], error: nil)
        await c.handleUploadCompletion(taskDescription: "garbage", status: 204, headers: [:], error: nil)
        XCTAssertEqual(try item("big"), big)
    }

    func testTaskDescriptionRoundTrip() {
        let d = TaskDescription(itemId: "ABC/L0/001#live", uploadId: "u-1", offset: 1_048_576)
        XCTAssertEqual(d.description, "ABC/L0/001#live|u-1|1048576")
        XCTAssertEqual(TaskDescription(parsing: d.description), d)
        XCTAssertEqual(TaskDescription(parsing: "a|b|c|7"), TaskDescription(itemId: "a|b", uploadId: "c", offset: 7))
        XCTAssertEqual(TaskDescription(parsing: "x||0"), TaskDescription(itemId: "x", uploadId: "", offset: 0))
        XCTAssertNil(TaskDescription(parsing: "x|y"))
        XCTAssertNil(TaskDescription(parsing: "|u|1"))
        XCTAssertNil(TaskDescription(parsing: "x|u|-1"))
    }

    func testRelaunchRestoresInFlightFromTaskDescription() async throws {
        let b = randomBytes(2500)
        library.put("big", b)
        // The OS keeps uploading the second chunk while the app is suspended and then killed.
        uploader.hold = { _, r in r.method == "PATCH" && r.header("Upload-Offset") == "1000" }
        let first = await controller(chunk: 1000).runOnce(budget: RunBudget(maxDurationMs: 300))
        XCTAssertEqual(first.stop, .budget)
        let desc = try XCTUnwrap(uploader.heldDescriptions.first)
        let row = try item("big")
        XCTAssertEqual(row.state, .uploading)
        XCTAssertEqual(row.uploadOffset, 1000)
        XCTAssertEqual(desc, "big|\(row.uploadId!)|1000")
        let chunk = staging.appendingPathComponent(EngineController.stagedName(itemId: "big") + ".1000.chunk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path))

        // Relaunch: a new process sees the task still in the background session.
        let pending = try XCTUnwrap(uploader.sent.last?.request)
        let relaunched = FakeUploader(restoring: [desc: pending])
        let c = controller(chunk: 1000, uploader: relaunched)
        let before = requests.count
        let second = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(requests.count, before, "nothing re-sent for an item the OS is still uploading")
        XCTAssertTrue(relaunched.sent.isEmpty)
        XCTAssertNotEqual(second.stop, .budget)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.path), "the launch sweep keeps in-flight chunks")

        // The task finishes: the completion maps back to the row and the next chunk goes out at once.
        await relaunched.release(desc)
        let done = try await waitUntil { try self.item("big").state == .backedUp }
        XCTAssertTrue(done)
        XCTAssertEqual(relaunched.sent.map(\.desc), ["big|\(row.uploadId!)|2000"])
        XCTAssertEqual(try item("big").assetId, server.assetId(sha256Hex(b)))
        XCTAssertEqual(requests.filter { $0.method == "PATCH" }.map { $0.header("Upload-Offset")! }, ["0", "1000", "2000"])
        XCTAssertEqual(stagedFiles(), [])
    }

    func testUneditedOriginalStackKey() async throws {
        let original = randomBytes(500, seed: 1)
        let edited = randomBytes(520, seed: 2)
        library.put("E", original)
        library.edit("E", rendition: edited, modifiedAtMs: 200)
        let c = controller()
        // Off by default: only the current rendition (H3).
        _ = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(server.creates.map { $0["sha256"] }, [sha256Hex(edited)])
        XCTAssertNil(server.creates[0]["stack_key"])

        var s = await c.getSettings()
        s.keepUneditedOriginals = true
        try await c.setSettings(s)
        _ = await c.runOnce(budget: RunBudget())
        let orig = try item(ItemRef(assetLocalId: "E", role: .original).rowId)
        XCTAssertEqual(orig.state, .backedUp)
        XCTAssertEqual(orig.stackKey, "E")
        XCTAssertEqual(try item("E").stackKey, "E")
        let last = try XCTUnwrap(server.creates.last)
        XCTAssertEqual(last["sha256"], sha256Hex(original))
        XCTAssertEqual(last["stack_key"], "E")
        XCTAssertNotEqual(server.assetId(sha256Hex(original)), server.assetId(sha256Hex(edited)))
    }

    /// Review Focus 2: an edit after backup is a new asset, and the old one is never freed by mistake.
    func testEditedAssetRehashed() async throws {
        let before = randomBytes(400, seed: 1)
        let after = randomBytes(450, seed: 2)
        library.put("P", before)
        let c = controller()
        _ = await c.runOnce(budget: RunBudget())
        let oldAsset = try XCTUnwrap(try item("P").assetId)

        library.edit("P", rendition: after, modifiedAtMs: 500)
        // Freeing before the next scan: the fingerprint changed, so nothing is deleted.
        let deleter = FakeDeleter()
        let freed = await c.freeUpSpace(["P"], deleter: deleter)
        XCTAssertEqual(freed.freedCount, 0)
        XCTAssertTrue(deleter.calls.isEmpty)
        XCTAssertEqual(freed.skipped.map(\.reason), ["fingerprint_changed"])

        _ = await c.runOnce(budget: RunBudget())
        let p = try item("P")
        XCTAssertEqual(p.state, .backedUp)
        XCTAssertEqual(p.sha256, sha256Hex(after))
        XCTAssertNotEqual(p.assetId, oldAsset)
        XCTAssertEqual(server.assetId(sha256Hex(before)), oldAsset, "the old asset stays on the server")
        XCTAssertEqual(library.exports.filter { $0 == "P#primary" }.count, 2, "re-read after the edit")
        XCTAssertFalse(requests.contains { $0.method == "DELETE" })
    }

    // MARK: - carried requirements

    func testTransientRefreshFailureRetriesWithinGraceWindow() async throws {
        library.put("g", randomBytes(300))
        let refreshes = Counter()
        server.override = { r in
            guard r.path == "/api/v1/auth/refresh" else { return nil }
            // The first two refreshes fail (e.g. the answer was lost after rotation).
            return refreshes.next() <= 2 ? .problem(503, "server_unavailable") : .json(200, tokensJSON(9))
        }
        let report = await controller().runOnce(budget: RunBudget())
        XCTAssertEqual(try item("g").state, .backedUp)
        XCTAssertEqual(try item("g").attempts, 0, "auth trouble is not the item's fault")
        XCTAssertEqual(refreshes.value, 3)
        XCTAssertEqual(report.stop, .idle)
        // Retried well inside the server's 30 s grace window, not after a generic backoff.
        XCTAssertLessThan(clock.slept.reduce(0, +), 30_000, "\(clock.slept)")
        XCTAssertEqual(store.wipes, 0)
    }

    func testPersistentRefreshFailureSchedulesInsideGraceWindow() async throws {
        library.put("g", randomBytes(300))
        server.override = { r in r.path == "/api/v1/auth/refresh" ? .problem(500, "internal") : nil }
        let report = await controller().runOnce(budget: RunBudget())
        XCTAssertEqual(report.stop, .authRetry)
        XCTAssertEqual(try item("g").attempts, 0)
        let next = try XCTUnwrap(report.nextAttemptAtMs)
        XCTAssertLessThanOrEqual(next - clock.nowMs(), 10_000)
        XCTAssertLessThan(clock.slept.reduce(0, +), 30_000)
    }

    func testLaunchSweepRemovesStaleChunksAndParts() async throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let names = ["gone-primary", "gone-primary.0.chunk", "x-primary.part", "y.4096.chunk.part", "keep-primary"]
        for n in names { try Data("x".utf8).write(to: staging.appendingPathComponent(n)) }
        try db.upsert(Item(localId: "keep", sha256: String(repeating: "a", count: 64), size: 1, modifiedAtMs: 100,
                           takenAtMs: 1, mime: "image/jpeg", kind: .photo, filename: "k", state: .hashed,
                           nextAttemptAtMs: clock.nowMs() + 3_600_000))
        let c = controller()
        await c.sweepStaging()
        XCTAssertEqual(stagedFiles(), [EngineController.stagedName(itemId: "keep")])
        XCTAssertEqual(EngineController.stagedName(itemId: "keep"), "keep-primary")
    }

    func testIdenticalContentNeverUploadsConcurrently() async throws {
        let b = randomBytes(700)
        library.put("d1", b)
        library.put("d2", b)
        _ = await controller().runOnce(budget: RunBudget())
        XCTAssertEqual(try item("d1").state, .backedUp)
        XCTAssertEqual(try item("d2").state, .backedUp)
        XCTAssertEqual(try item("d1").assetId, try item("d2").assetId)
        XCTAssertEqual(uploader.sent.filter { !$0.request.body.isEmpty }.count, 1, "the bytes go up once")
        XCTAssertEqual(try item("d2").attempts, 0)
    }

    func testPassLimitWithDueWorkReportsBudget() async throws {
        library.putLive("L", still: randomBytes(300, seed: 1), video: randomBytes(310, seed: 2))
        // One pass backs up the still; its video becomes due only afterwards (H4).
        let report = await controller(maxPasses: 1).runOnce(budget: RunBudget())
        XCTAssertEqual(try item("L").state, .backedUp)
        XCTAssertEqual(try item(ItemRef(assetLocalId: "L", role: .liveVideo).rowId).state, .queued)
        XCTAssertEqual(report.stop, .budget)
        XCTAssertEqual(report.nextAttemptAtMs, clock.nowMs())
    }

    func testClockJumpBackTreatsFarFutureBackoffAsDue() async throws {
        library.put("j", randomBytes(300))
        let c = controller()
        _ = await c.runOnce(budget: RunBudget())
        var j = try item("j")
        j.state = .queued
        j.assetId = nil
        j.nextAttemptAtMs = clock.nowMs() + 2 * 60 * 60 * 1000 // beyond the 15 min cap: the clock went back
        try db.upsert(j)
        _ = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(try item("j").state, .backedUp)
    }

    func testRetryAndUndoSkip() async throws {
        let b = randomBytes(200)
        server.tombstone(sha256Hex(b))
        library.put("u", b)
        let c = controller()
        _ = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(try item("u").state, .skipped)
        let undone = await c.undoSkip(sha256Hex(b))
        XCTAssertTrue(undone)
        XCTAssertEqual(try item("u").state, .hashed)
        _ = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(try item("u").state, .backedUp)
        XCTAssertTrue(requests.contains { $0.method == "DELETE" && $0.path == "/api/v1/tombstones/\(sha256Hex(b))" })
    }

    func testStatusAndNetworkChange() async throws {
        library.put("s", randomBytes(300))
        let c = controller()
        _ = await c.runOnce(budget: RunBudget())
        let status = await c.status()
        XCTAssertEqual(status.backedUp, 1)
        XCTAssertEqual(status.total, 1)
        XCTAssertEqual(status.queued, 0)
        XCTAssertFalse(status.paused)
        XCTAssertNotNil(status.lastRunAtMs)
        XCTAssertFalse(events.statuses.isEmpty)
        c.onNetworkChanged()
        await c.pause(.user)
        let paused = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(paused.stop, .paused)
        await c.start()
        let s2 = await c.status()
        XCTAssertFalse(s2.paused)
    }
}

/// Cancels a task from inside a fake (the run being "killed").
final class KillSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<RunReport, Never>?
    private var fired = false

    func set(_ t: Task<RunReport, Never>) {
        lock.lock()
        task = t
        let f = fired
        lock.unlock()
        if f { t.cancel() }
    }

    func fire() {
        lock.lock()
        fired = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

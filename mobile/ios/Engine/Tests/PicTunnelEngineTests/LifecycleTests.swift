import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PicTunnelEngine

/// A latch a stub handler (which runs on its own thread) can block on.
final class Latch: @unchecked Sendable {
    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var opened = false
    private var _waiting = 0

    /// Blocks until `open()` or `timeout` seconds.
    func wait(timeout: TimeInterval = 30) {
        lock.lock(); _waiting += 1; lock.unlock()
        _ = sem.wait(timeout: .now() + timeout)
        sem.signal() // let any other waiter through too once open
    }

    func open() {
        lock.lock()
        defer { lock.unlock() }
        guard !opened else { return }
        opened = true
        sem.signal()
    }

    var waiting: Int { lock.lock(); defer { lock.unlock() }; return _waiting }
}

/// The pairing lifecycle, mirroring the Kotlin `AuthUnpairRaceTest`, `SessionEndTest` and
/// `AccountTest`: a refresh racing an unpair or a new pairing never brings old credentials back,
/// nothing is handed out or rebuilt while a session ends, unpair is bounded even against an
/// endpoint that never answers, runs are stopped and awaited, and unpair keeps cached hashes and
/// the user's settings.
final class LifecycleTests: XCTestCase {
    private let sid = "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f"
    private let fp = "xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc"

    private func qr(_ serverId: String) -> String {
        "pictunnel://pair?v=1&sid=\(serverId)&code=K7Q2-M9XD-4T&fp=\(fp)&u=https%3A%2F%2Fphotos.example.com"
    }

    private func redeemBody(_ serverId: String) -> String {
        #"{"server_id":"\#(serverId)","user":{"id":"u1","username":"ana","display_name":"Ana","role":"admin"},"#
            + #""device":{"id":"dev-1","name":"p","platform":"ios","app_version":"0.1.0","created_at":"2026-10-03T12:00:00Z"},"#
            + #""tokens":\#(tokensJSON(0))}"#
    }

    /// Redeem and info for `serverId`; refresh and logout as given (default: answered at once).
    private func installServer(serverId: String, refresh: (@Sendable () -> StubReply)? = nil,
                               logout: (@Sendable () -> StubReply)? = nil) {
        let redeem = redeemBody(serverId)
        let info = #"{"server_id":"\#(serverId)","name":"Server \#(serverId.suffix(2))"}"#
        StubServer.shared.install { r in
            switch (r.method, r.path) {
            case ("POST", Pairer.redeemPath): return .json(201, redeem)
            case ("GET", "/healthz"): return .empty(200)
            case ("GET", "/api/v1/server/info"): return .json(200, info)
            case ("POST", "/api/v1/auth/refresh"): return refresh?() ?? .json(200, tokensJSON(1))
            case ("POST", "/api/v1/auth/logout"): return logout?() ?? .empty(204)
            default: return .empty(404)
            }
        }
    }

    private func runtime(store: InMemoryCredentialStore, db: EngineDB, library: FakeLibrary = FakeLibrary(),
                         events: RecordingEvents = RecordingEvents()) throws -> EngineRuntime {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return EngineRuntime(store: store, library: library, uploader: FakeUploader(), events: events, db: db,
                             config: EngineConfig(stagingDir: dir), appVersion: "0.1.0", clock: FakeClock(),
                             pinning: PinningDelegate(store: store)) { _ in stubHTTP() }
    }

    private func auth(_ store: CredentialStore, onNeedsRepair: (@Sendable () -> Void)? = nil) -> AuthManager {
        let endpoints = Endpoints(["https://pictunnel.test"])
        return AuthManager(store: store, http: stubHTTP(), endpoints: endpoints, onNeedsRepair: onNeedsRepair)
    }

    private func refreshes() -> Int {
        StubServer.shared.requests.filter { $0.path == "/api/v1/auth/refresh" }.count
    }

    // MARK: - AuthUnpairRace

    func testRefreshInFlightDuringUnpairDoesNotRestoreCredentials() async throws {
        let release = Latch()
        defer { release.open() }
        installServer(serverId: sid, refresh: {
            release.wait()
            return .json(200, tokensJSON(1))
        })
        let store = InMemoryCredentialStore(testCredentials())
        let auth = auth(store)
        let pending = Task { try await auth.accessToken() }
        let started = await waitUntil { release.waiting == 1 }
        XCTAssertTrue(started, "the refresh is in flight")

        let begun = Date()
        _ = await auth.close { try? store.wipe() }
        XCTAssertLessThan(Date().timeIntervalSince(begun), 3, "close cancels the refresh instead of waiting it out")
        release.open()
        do {
            _ = try await pending.value
            XCTFail("the refresh of a closed session gives no token")
        } catch {}
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(store.creds, "the wipe stands")
        XCTAssertTrue(store.saved.isEmpty, "the late answer saved nothing")

        // A closed session never refreshes again.
        do {
            _ = try await auth.accessToken()
            XCTFail("expected needsRepair")
        } catch {
            XCTAssertEqual(error as? AuthError, .needsRepair)
        }
        XCTAssertEqual(refreshes(), 1)
        let closed = await auth.isClosed
        XCTAssertTrue(closed)
    }

    func testAWipeThatBypassesTheLockIsNotUndoneByTheRefreshSave() async throws {
        let release = Latch()
        defer { release.open() }
        installServer(serverId: sid, refresh: {
            release.wait()
            return .json(200, tokensJSON(1))
        })
        let store = InMemoryCredentialStore(testCredentials())
        let repairs = Counter()
        let auth = auth(store) { repairs.next() }
        let pending = Task { await auth.onUnauthorized() }
        let started = await waitUntil { release.waiting == 1 }
        XCTAssertTrue(started)

        try store.wipe()
        release.open()
        let outcome = await pending.value
        XCTAssertEqual(outcome, .needsRepair(nil))
        XCTAssertNil(store.creds, "the rotated token did not bring the wiped credentials back")
        XCTAssertTrue(store.saved.isEmpty)
        XCTAssertEqual(repairs.value, 0, "a wipe someone else made is not reported again")
    }

    func testANewPairingDuringTheRefreshKeepsTheNewCredentials() async throws {
        let release = Latch()
        defer { release.open() }
        installServer(serverId: sid, refresh: {
            release.wait()
            return .json(200, tokensJSON(1))
        })
        let store = InMemoryCredentialStore(testCredentials())
        let auth = auth(store)
        let pending = Task { await auth.onUnauthorized() }
        let started = await waitUntil { release.waiting == 1 }
        XCTAssertTrue(started)

        var fresh = testCredentials()
        fresh.refreshToken = "pt_rt_new_pairing"
        try store.save(fresh)
        release.open()
        let outcome = await pending.value
        XCTAssertEqual(outcome, .needsRepair(nil))
        XCTAssertEqual(store.creds, fresh, "the new pairing's credentials stay")
    }

    // MARK: - SessionEnd

    func testUnpairReturnsWithinTheLogoutDeadlineAgainstABlackHoledEndpoint() async throws {
        let hole = Latch()
        defer { hole.open() }
        // Neither the refresh (the logout needs a token first) nor the logout ever answers.
        installServer(serverId: sid, refresh: {
            hole.wait(timeout: 60)
            return .json(200, tokensJSON(1))
        }, logout: {
            hole.wait(timeout: 60)
            return .empty(204)
        })
        let store = InMemoryCredentialStore(testCredentials())
        let events = RecordingEvents()
        let rt = try runtime(store: store, db: try EngineDB.inMemory(), events: events)
        XCTAssertTrue(rt.isPaired)

        let begun = Date()
        await rt.unpair()
        let took = Date().timeIntervalSince(begun)
        XCTAssertGreaterThanOrEqual(took, EngineRuntime.logoutTimeoutSeconds - 0.5, "the logout got its chance")
        XCTAssertLessThan(took, EngineRuntime.logoutTimeoutSeconds + 2, "unpair does not wait for the dead endpoint")
        XCTAssertNil(store.creds)
        XCTAssertFalse(rt.isPaired)
        XCTAssertNil(rt.connection())
        XCTAssertEqual(events.repairs, 0)
    }

    func testASessionRequestedDuringASlowUnpairIsNotRebuiltAfterTheWipe() async throws {
        let release = Latch()
        defer { release.open() }
        installServer(serverId: sid, logout: {
            release.wait()
            return .empty(204)
        })
        let store = InMemoryCredentialStore(testCredentials())
        let rt = try runtime(store: store, db: try EngineDB.inMemory())
        XCTAssertTrue(rt.isPaired)

        let unpairing = Task { await rt.unpair() }
        let atLogout = await waitUntil { release.waiting == 1 }
        XCTAssertTrue(atLogout, "unpair is waiting for the logout")
        XCTAssertNotNil(store.creds, "the credentials are not wiped yet")
        XCTAssertFalse(rt.isPaired, "but no engine is handed out meanwhile")
        XCTAssertNil(rt.controller())
        XCTAssertNil(rt.connection())
        do {
            _ = try await rt.accessToken()
            XCTFail("expected notPaired")
        } catch {
            XCTAssertEqual(error as? RuntimeError, .notPaired)
        }

        release.open()
        await unpairing.value
        XCTAssertNil(store.creds)
        XCTAssertFalse(rt.isPaired, "nothing built from the old credentials outlives the wipe")
    }

    func testNeedsRepairDuringUnpairIsNotSentToTheApp() async throws {
        // The logout's refresh learns the refresh token was reused: credentials are wiped anyway,
        // and the app, which is unpairing, is not sent to the pairing screen a second time.
        installServer(serverId: sid, refresh: { .problem(401, "refresh_token_reused") })
        let store = InMemoryCredentialStore(testCredentials())
        let events = RecordingEvents()
        let rt = try runtime(store: store, db: try EngineDB.inMemory(), events: events)
        XCTAssertTrue(rt.isPaired)
        await rt.unpair()
        XCTAssertEqual(events.repairs, 0)
        XCTAssertNil(store.creds)
    }

    func testUnpairStopsAndAwaitsTheRunInProgress() async throws {
        installServer(serverId: sid)
        let library = FakeLibrary()
        let scanning = Counter()
        library.beforeScan = {
            scanning.next()
            // A scan that only ends when cancelled.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
        let store = InMemoryCredentialStore(testCredentials())
        let db = try EngineDB.inMemory()
        let rt = try runtime(store: store, db: db, library: library)
        let finished = Counter()
        rt.onRunFinished = { _ in finished.next() }

        let run = Task { await rt.runOnce(budget: RunBudget()) }
        let inScan = await waitUntil { scanning.value == 1 }
        XCTAssertTrue(inScan)
        XCTAssertEqual(rt.runningRuns, 1)

        await rt.unpair()
        XCTAssertEqual(rt.runningRuns, 0, "unpair returned only after the run ended")
        let report = await run.value
        XCTAssertNil(report, "a preempted run reports nothing")
        XCTAssertEqual(finished.value, 0, "and schedules nothing")

        // No run starts unpaired.
        let after = await rt.runOnce(budget: RunBudget())
        XCTAssertNil(after)
    }

    // MARK: - Account

    private func seed(_ db: EngineDB) throws {
        try db.upsert(Item(localId: "a", size: 1, modifiedAtMs: 1, takenAtMs: 1, mime: "image/jpeg", kind: .photo,
                           filename: "a.jpg", state: .backedUp, assetId: "x"))
        try db.putHash(localId: "a", modifiedAtMs: 1, size: 1, sha256: String(repeating: "a", count: 64))
        try db.setScanToken(scope: Pipeline.scanScope, token: Data("s1".utf8))
        _ = try db.addActivity(atMs: 1, kind: ActivityLog.info, localId: nil, message: "m")
        try SettingsRepo(db: db).setPause(PauseState(reason: .quota, untilMs: nil))
        try SettingsRepo(db: db).setLastRunAtMs(5)
    }

    private func customSettings() -> EngineSettings {
        var s = EngineSettings()
        s.wifiOnly = true
        s.chargingOnly = true
        s.includeVideos = false
        s.keepUneditedOriginals = true
        s.allAlbums = false
        s.albumIds = ["album-1"]
        s.uploadConcurrency = 3
        return s
    }

    func testUnpairForgetsTheIndexButKeepsHashesAndSettings() async throws {
        installServer(serverId: sid)
        let store = InMemoryCredentialStore()
        let db = try EngineDB.inMemory()
        let rt = try runtime(store: store, db: db)
        _ = try await rt.pair(PairInput(qrUri: qr(sid), deviceName: "p"))
        try SettingsRepo(db: db).set(customSettings())
        try seed(db)

        await rt.unpair()
        XCTAssertNil(try db.item(localId: "a"), "the index is gone")
        XCTAssertNil(try db.scanToken(scope: Pipeline.scanScope))
        XCTAssertTrue(try db.latestActivity(limit: 10).isEmpty)
        XCTAssertNil(SettingsRepo(db: db).pause())
        XCTAssertNil(SettingsRepo(db: db).lastRunAtMs())
        XCTAssertNil(try db.setting(EngineRuntime.serverIdKey))
        XCTAssertNil(try db.setting(EngineRuntime.serverNameKey))
        XCTAssertEqual(try db.cachedHash(localId: "a", modifiedAtMs: 1, size: 1), String(repeating: "a", count: 64),
                       "cached hashes describe the phone's files and stay")
        XCTAssertEqual(SettingsRepo(db: db).get(), customSettings(), "the user's settings stay")

        // Settings survive unpair → pair.
        _ = try await rt.pair(PairInput(qrUri: qr(sid), deviceName: "p"))
        XCTAssertEqual(SettingsRepo(db: db).get(), customSettings())
        XCTAssertEqual(try db.setting(EngineRuntime.serverIdKey), sid)
    }

    func testPairingADifferentServerClearsTheOldIndexAndStopsTheRun() async throws {
        installServer(serverId: sid)
        let library = FakeLibrary()
        let store = InMemoryCredentialStore()
        let db = try EngineDB.inMemory()
        let rt = try runtime(store: store, db: db, library: library)
        _ = try await rt.pair(PairInput(qrUri: qr(sid), deviceName: "p"))
        try SettingsRepo(db: db).set(customSettings())
        try seed(db)

        let scanning = Counter()
        library.beforeScan = {
            scanning.next()
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
        var s = customSettings()
        s.wifiOnly = false
        s.chargingOnly = false
        try SettingsRepo(db: db).set(s)
        try SettingsRepo(db: db).clearPause()
        let run = Task { await rt.runOnce(budget: RunBudget()) }
        let inScan = await waitUntil { scanning.value == 1 }
        XCTAssertTrue(inScan)

        let other = "01928f3e-0000-7000-8000-0000000000b2"
        installServer(serverId: other)
        _ = try await rt.pair(PairInput(qrUri: qr(other), deviceName: "p"))
        let report = await run.value
        XCTAssertNil(report, "the run in progress was stopped before the index changed")
        XCTAssertEqual(rt.runningRuns, 0)
        XCTAssertNil(try db.item(localId: "a"), "what was backed up there says nothing here")
        XCTAssertNil(try db.scanToken(scope: Pipeline.scanScope))
        XCTAssertNotNil(try db.cachedHash(localId: "a", modifiedAtMs: 1, size: 1))
        XCTAssertEqual(SettingsRepo(db: db).get(), s)
        XCTAssertEqual(try db.setting(EngineRuntime.serverIdKey), other)
        XCTAssertEqual(rt.connection()?.serverId, other)
    }

    func testPairingTheSameServerAgainKeepsTheIndex() async throws {
        installServer(serverId: sid)
        let store = InMemoryCredentialStore()
        let db = try EngineDB.inMemory()
        let rt = try runtime(store: store, db: db)
        _ = try await rt.pair(PairInput(qrUri: qr(sid), deviceName: "p"))
        try seed(db)
        _ = try await rt.pair(PairInput(qrUri: qr(sid), deviceName: "p"))
        XCTAssertEqual(try db.item(localId: "a")?.state, .backedUp)
        XCTAssertNotNil(try db.scanToken(scope: Pipeline.scanScope))
        XCTAssertNil(SettingsRepo(db: db).pause(), "a pause belonged to the old pairing")
    }

    func testAFailedPairingLeavesTheOldPairingAsItWas() async throws {
        installServer(serverId: sid)
        let store = InMemoryCredentialStore()
        let db = try EngineDB.inMemory()
        let rt = try runtime(store: store, db: db)
        _ = try await rt.pair(PairInput(qrUri: qr(sid), deviceName: "p"))
        try seed(db)
        let before = store.creds

        StubServer.shared.install { r in
            r.path == Pairer.redeemPath ? .problem(400, "pairing_code_invalid") : .empty(404)
        }
        do {
            _ = try await rt.pair(PairInput(qrUri: qr("01928f3e-0000-7000-8000-0000000000b2"), deviceName: "p"))
            XCTFail("expected pairing_code_invalid")
        } catch let e as PairingError {
            XCTAssertEqual(e.code, "pairing_code_invalid")
        }
        XCTAssertEqual(store.creds, before)
        XCTAssertEqual(try db.item(localId: "a")?.state, .backedUp)
        XCTAssertTrue(rt.isPaired, "the old pairing works again")
        XCTAssertEqual(rt.connection()?.serverId, sid)
    }

    // MARK: - runs

    func testGatePreemptCancelsAwaitsAndRefusesNewRuns() async throws {
        let gate = RunGate()
        let ended = Counter()
        let run = Task {
            await gate.run { () async -> Int? in
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                ended.next()
                return 1
            }
        }
        let started = await waitUntil { gate.running == 1 }
        XCTAssertTrue(started)
        let inside: Int? = await gate.preempt {
            XCTAssertEqual(ended.value, 1, "the run ended before the block")
            return await gate.run { 2 }
        }
        XCTAssertNil(inside, "no run starts during a preemption")
        let out = await run.value
        XCTAssertNil(out, "a preempted run returns nil")
        let later = await gate.run { 3 }
        XCTAssertEqual(later, 3)
    }

    func testCancellingTheCallerCancelsTheRun() async throws {
        let gate = RunGate()
        let run = Task {
            await gate.run { () async -> Bool? in
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
                return Task.isCancelled
            }
        }
        _ = await waitUntil { gate.running == 1 }
        run.cancel()
        let out = await run.value
        XCTAssertEqual(out, true)
        XCTAssertEqual(gate.running, 0)
    }

    func testShortRunsLeaveFullScansToLongerRuns() async throws {
        installServer(serverId: sid)
        let library = FakeLibrary()
        library.put("p1", Data("one".utf8))
        let store = InMemoryCredentialStore(testCredentials())
        let db = try EngineDB.inMemory()
        let rt = try runtime(store: store, db: db, library: library)

        // No change token yet: only a full scan would do, and a refresh-sized run skips it.
        _ = await rt.runOnce(budget: RunBudget(maxDurationMs: 25_000, allowFullScan: false))
        XCTAssertEqual(library.deferredScans, 1)
        XCTAssertEqual(library.scans, 0)
        XCTAssertNil(try db.item(localId: "p1"))
        XCTAssertNil(try db.scanToken(scope: Pipeline.scanScope))

        // A processing (or foreground) run does it; later short runs scan incrementally.
        _ = await rt.runOnce(budget: RunBudget())
        XCTAssertEqual(library.scans, 1)
        XCTAssertNotNil(try db.item(localId: "p1"))
        library.put("p2", Data("two".utf8))
        _ = await rt.runOnce(budget: RunBudget(maxDurationMs: 25_000, allowFullScan: false))
        XCTAssertEqual(library.scans, 2)
        XCTAssertNotNil(try db.item(localId: "p2"))
    }

    func testTheBudgetCoversTheScan() async throws {
        installServer(serverId: sid)
        let library = FakeLibrary()
        library.put("p1", Data("one".utf8))
        library.beforeScan = {
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
            throw CancellationError()
        }
        let store = InMemoryCredentialStore(testCredentials())
        let db = try EngineDB.inMemory()
        let rt = try runtime(store: store, db: db, library: library)

        let begun = Date()
        let report = await rt.runOnce(budget: RunBudget(maxDurationMs: 300))
        XCTAssertLessThan(Date().timeIntervalSince(begun), 3, "a scan that overruns the budget is cancelled")
        XCTAssertEqual(report?.stop, .budget)
        XCTAssertNil(try db.scanToken(scope: Pipeline.scanScope), "a cancelled scan keeps no token")
        let errors = try db.latestActivity(limit: 10).filter { $0.kind == ActivityLog.error }
        XCTAssertTrue(errors.isEmpty, "running out of time is not a scan error")
    }

    // MARK: - pinning and alerts

    func testAnUnreadablePinIsTransientNeverARejection() {
        struct Locked: Error {}
        let delegate = PinningDelegate { throw Locked() }
        XCTAssertEqual(delegate.verdict { _ in false }, .unavailable)
        XCTAssertEqual(delegate.verdict { $0 == nil }, .accept, "a chain the system trusts needs no pin")
        let pinned = PinningDelegate { "pin" }
        XCTAssertEqual(pinned.verdict { $0 == "pin" }, .accept)
        XCTAssertEqual(pinned.verdict { _ in false }, .reject)
        XCTAssertEqual(PinningDelegate(store: UnreadableStore()).verdict { _ in false }, .unavailable)

        let f = TransportFailure(handshake: .pinUnavailable, error: URLError(.cancelled), sent: nil)
        XCTAssertTrue(f.provablyUnsent)
        XCTAssertFalse(f.isTLS)
        XCTAssertEqual(Transport.classify(f), .offline, "never a pin rejection, never an attempt")
        let r = TransportFailure(handshake: .pinRejected(host: "h"), error: URLError(.cancelled), sent: nil)
        XCTAssertEqual(r.pinRejectedHost, "h")
        XCTAssertEqual(Transport.classify(r), .tls)
    }

    func testHandshakeRecordsAreKeptPerSession() {
        let delegate = PinningDelegate { "pin" }
        let a = URLSession(configuration: .ephemeral)
        let b = URLSession(configuration: .ephemeral)
        delegate.record(.pinRejected(host: "a.example"), session: a, taskIdentifier: 1)
        delegate.record(.pinUnavailable, session: b, taskIdentifier: 1)
        XCTAssertEqual(delegate.takeFailure(session: b, taskIdentifier: 1), .pinUnavailable)
        XCTAssertEqual(delegate.takeFailure(session: a, taskIdentifier: 1), .pinRejected(host: "a.example"))
        XCTAssertNil(delegate.takeFailure(session: a, taskIdentifier: 1), "consumed")
        XCTAssertEqual(delegate.rejectedHosts, ["a.example"])
    }

    func testOneAlertPerPauseEpisode() {
        func status(_ reason: PauseReason?) -> BackupStatus {
            BackupStatus(backedUp: 0, total: 0, queued: 0, uploading: nil, needsAttention: 0, skipped: 0,
                         freeableBytes: 0, paused: reason != nil, pauseReason: reason, lastRunAtMs: nil, preparing: 0)
        }
        var notified: PauseReason?
        var posted: [PauseReason] = []
        for s in [status(nil), status(.serverFull), status(.serverFull), status(.serverFull), status(nil),
                  status(.quota), status(.quota), status(.user), status(.quota)] {
            let d = PauseAlerts.next(status: s, notified: notified)
            if let p = d.post { posted.append(p) }
            notified = d.notified
        }
        XCTAssertEqual(posted, [.serverFull, .quota, .quota])
    }
}

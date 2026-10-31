import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import XCTest
@testable import PicTunnelEngine

/// A real `pictunnel serve` process on loopback ports with a throwaway data dir.
final class RealServer: @unchecked Sendable {
    let process: Process
    let dataDir: URL
    let httpsPort: Int
    let localPort: Int
    let pin: String
    private(set) var adminToken = ""
    private let session = URLSession(configuration: .ephemeral)

    private init(process: Process, dataDir: URL, httpsPort: Int, localPort: Int, pin: String) {
        self.process = process
        self.dataDir = dataDir
        self.httpsPort = httpsPort
        self.localPort = localPort
        self.pin = pin
    }

    static func start(bin: String) throws -> RealServer {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("pictunnel-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let https = try freePort(), local = try freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = [
            "serve", "--data-dir=\(data.path)",
            "--server.https-addr=127.0.0.1:\(https)", "--server.local-addr=127.0.0.1:\(local)",
            "--discovery.mdns=false", "--server.public-urls=https://127.0.0.1:\(https)",
            "--rate-limit.enabled=false", "--upload.recommended-chunk-bytes=1048576",
            "--storage.reserve-bytes=0", "--log.level=warn",
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()

        // Read stdout until the pin, the listening line and the setup token are seen.
        var pin: String?, listening = false, token: String?
        var buffer = Data()
        let deadline = Date().addingTimeInterval(60)
        let handle = out.fileHandleForReading
        while pin == nil || !listening || token == nil {
            guard Date() < deadline else {
                p.terminate()
                throw XCTSkip("server did not start")
            }
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            for line in String(decoding: buffer, as: UTF8.self).split(separator: "\n") {
                if let r = line.range(of: "certificate pin ") { pin = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
                if line.contains(" listening on ") { listening = true }
                if let r = line.range(of: "PicTunnel-Setup-Token:") {
                    token = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        guard let pin, listening, token?.isEmpty == false else {
            p.terminate()
            throw NSError(domain: "it", code: 1, userInfo: [NSLocalizedDescriptionKey: "server output incomplete"])
        }
        let s = RealServer(process: p, dataDir: data, httpsPort: https, localPort: local, pin: pin)
        try s.setupAdmin()
        return s
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: dataDir)
    }

    var localBase: String { "http://127.0.0.1:\(localPort)" }

    /// Calls the loopback listener, where setup needs no token (P§6.3).
    @discardableResult
    func local(_ method: String, _ path: String, _ body: String? = nil, token: String? = nil,
               auth: Bool = true) throws -> (Int, JSONValue?) {
        var r = URLRequest(url: URL(string: localBase + path)!)
        r.httpMethod = method
        r.setValue("ios/0.1.0", forHTTPHeaderField: "PicTunnel-Client")
        r.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        if auth { r.setValue("Bearer \(token ?? adminToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpBody = Data(body.utf8)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try syncSend(r)
        let json = data.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: data)
        return (resp.statusCode, json)
    }

    private func syncSend(_ r: URLRequest) throws -> (Data, HTTPURLResponse) {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Data, HTTPURLResponse), Error> = .failure(URLError(.unknown))
        session.dataTask(with: r) { d, resp, e in
            if let e { result = .failure(e) } else { result = .success((d ?? Data(), resp as! HTTPURLResponse)) }
            sem.signal()
        }.resume()
        sem.wait()
        return try result.get()
    }

    private func setupAdmin() throws {
        let (s, _) = try local("POST", "/api/v1/auth/setup",
                               #"{"username":"alice","password":"correct horse battery","display_name":"Alice"}"#,
                               auth: false)
        guard s == 201 else { throw NSError(domain: "it", code: s) }
        let (l, body) = try local(
            "POST", "/api/v1/auth/login",
            #"{"username":"alice","password":"correct horse battery","mode":"tokens","device":{"device_name":"it-admin","platform":"other","app_version":"0.1.0"}}"#,
            auth: false)
        guard l == 200, let t = body?["tokens"]?["access_token"]?.stringValue else { throw NSError(domain: "it", code: l) }
        adminToken = t
    }

    func pairingURI() throws -> String {
        let (s, body) = try local("POST", "/api/v1/pairing/codes")
        guard s == 201, let uri = body?["qr_uri"]?.stringValue else { throw NSError(domain: "it", code: s) }
        return uri
    }

    /// Active and trashed assets of the admin with this content hash.
    func assets(sha256: String) throws -> [JSONValue] {
        let (s, body) = try local("GET", "/api/v1/sync/snapshot?limit=1000")
        guard s == 200 else { throw NSError(domain: "it", code: s) }
        return (body?["assets"]?.arrayValue ?? []).filter { $0["sha256"]?.stringValue == sha256 }
    }

    static func freePort() throws -> Int {
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) == 0 && getsockname(s, $0, &len) == 0 }
        }
        guard ok else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// Network faults for uploads, wrapped around the real `ForegroundUploader`. `dropPatch` makes the
/// n-th PATCH (1-based) lose its connection once: `sendBytes` > 0 sends that prefix of the chunk to
/// the server first (the server keeps it), 0 sends nothing; `beforeDrop` runs just before.
final class ChaosUploader: BackgroundUploader, @unchecked Sendable {
    let inner: ForegroundUploader
    private let session: URLSession
    private let lock = NSLock()
    private var handler: (@Sendable (UploadCompletion) async -> Void)?
    private var patches = 0
    private var _lines: [String] = []
    var dropPatch = 0
    var sendBytes = 0
    var beforeDrop: @Sendable (URLRequest) -> Void = { _ in }

    /// Tasks "still running in the OS": not sent until `release`.
    var hold: @Sendable (URLRequest) -> Bool = { _ in false }
    private var held: [String: HeldTask] = [:]

    struct HeldTask: @unchecked Sendable {
        let request: URLRequest
        let file: URL?
    }

    init(session: URLSession, restoring: [String: HeldTask] = [:]) {
        self.session = session
        inner = ForegroundUploader(session: session)
        held = restoring
    }

    var heldTasks: [String: HeldTask] { lock.lockSync(); defer { lock.unlockSync() }; return held }

    /// Sends a held task now, through this uploader's session and completion handler.
    func release(_ desc: String) async throws {
        lock.lockSync()
        let t = held.removeValue(forKey: desc)
        lock.unlockSync()
        guard let t else { return }
        try await inner.enqueue(request: t.request, file: t.file, taskDescription: desc)
    }

    var lines: [String] { lock.lockSync(); defer { lock.unlockSync() }; return _lines }

    func setCompletionHandler(_ handler: @escaping @Sendable (UploadCompletion) async -> Void) {
        lock.lockSync(); self.handler = handler; lock.unlockSync()
        inner.setCompletionHandler(handler)
    }

    func pendingTaskDescriptions() async -> [String] {
        let running = await inner.pendingTaskDescriptions()
        return running + heldTasks.keys
    }

    func enqueue(request: URLRequest, file: URL?, taskDescription: String) async throws {
        if hold(request) {
            lock.lockSync()
            held[taskDescription] = HeldTask(request: request, file: file)
            lock.unlockSync()
            return
        }
        lock.lockSync()
        let at = request.httpMethod == "PATCH" ? " @\(request.value(forHTTPHeaderField: "Upload-Offset") ?? "?")" : ""
        _lines.append("\(request.httpMethod ?? "?") \(request.url?.path ?? "")\(at)")
        var drop = false
        if request.httpMethod == "PATCH" {
            patches += 1
            if patches == dropPatch {
                dropPatch = 0
                drop = true
            }
        }
        let h = handler
        let prefix = sendBytes
        lock.unlockSync()
        guard drop, let file else {
            return try await inner.enqueue(request: request, file: file, taskDescription: taskDescription)
        }
        beforeDrop(request)
        if prefix > 0 {
            // The first bytes reach the server, then the connection drops before any answer.
            let part = file.deletingLastPathComponent().appendingPathComponent("chaos-\(UUID().uuidString).bin")
            try Data(try Data(contentsOf: file).prefix(prefix)).write(to: part)
            let session = self.session
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                session.uploadTask(with: request, fromFile: part) { _, _, _ in done.resume() }.resume()
            }
            try? FileManager.default.removeItem(at: part)
        }
        Task {
            await h?(UploadCompletion(taskDescription: taskDescription, status: nil, headers: [:], body: nil,
                                      error: URLError(.networkConnectionLost)))
        }
    }
}

/// The iOS engine against a real `pictunnel` server (Task 13). Skipped unless `PICTUNNEL_BIN`
/// names a server binary built for this platform. On Linux, where URLSession cannot evaluate
/// server trust, the engine talks to the loopback HTTP listener; on Apple platforms it uses the
/// HTTPS listener with the paired pin.
final class ServerIntegrationTests: XCTestCase {
    nonisolated(unsafe) private static var server: RealServer?

    override class func setUp() {
        super.setUp()
        guard let bin = ProcessInfo.processInfo.environment["PICTUNNEL_BIN"], !bin.isEmpty else { return }
        server = try? RealServer.start(bin: bin)
    }

    override class func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private var dir: URL!
    private var db: EngineDB!
    private var store: InMemoryCredentialStore!
    private let library = FakeLibrary()
    private let clock = FakeClock()
    private let events = RecordingEvents()
    private var chaos: ChaosUploader!

    private var server: RealServer {
        get throws {
            guard ProcessInfo.processInfo.environment["PICTUNNEL_BIN"]?.isEmpty == false else {
                throw XCTSkip("PICTUNNEL_BIN is not set")
            }
            return try XCTUnwrap(Self.server, "the server failed to start")
        }
    }

    override func setUp() async throws {
        let server = try self.server
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try EngineDB(path: dir.appendingPathComponent("engine.sqlite").path)
        store = InMemoryCredentialStore()
        try await pair(server)
    }

    override func tearDown() async throws {
        db = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Pairs like the app does: parse the QR (P§10.3), redeem, keep the endpoints and the pin.
    private func pair(_ server: RealServer) async throws {
        let info = try PairURI.parse(try server.pairingURI()).get()
        XCTAssertEqual(Pinning.normalize(info.fingerprint), Pinning.normalize(server.pin))
        #if canImport(Security)
        let endpoints = info.endpoints
        #else
        let endpoints = [server.localBase]
        #endif
        let http = EngineHTTP(session: makeSession(pin: info.fingerprint), clientHeader: clientHeaderValue)
        let e = Endpoints(endpoints)
        let body = #"{"code":"\#(info.code)","device":{"device_name":"IT iPhone","platform":"ios","app_version":"0.1.0"}}"#
        let (data, resp) = try await e.execute(http, path: "/api/v1/pairing/redeem") { url in
            var r = URLRequest(url: url)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(body.utf8)
            return r
        }
        XCTAssertEqual(resp.statusCode, 201)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(json["server_id"]?.stringValue, info.serverId)
        XCTAssertEqual(json["user"]?["username"]?.stringValue, "alice")
        try store.save(Credentials(
            serverId: info.serverId, endpoints: endpoints, pinSpki: info.fingerprint,
            refreshToken: try XCTUnwrap(json["tokens"]?["refresh_token"]?.stringValue),
            deviceId: json["device"]?["id"]?.stringValue ?? ""))
    }

    private func makeSession(pin: String) -> URLSession {
        #if canImport(Security)
        return EngineHTTP.makeSession(pinning: PinningDelegate(pin: { pin }), clientHeader: clientHeaderValue)
        #else
        return EngineHTTP.makeSession(pinning: nil, clientHeader: clientHeaderValue)
        #endif
    }

    private func controller(chunk: Int64 = 1 << 20, restoring: [String: ChaosUploader.HeldTask] = [:]) -> EngineController {
        let creds = store.creds!
        let endpoints = Endpoints(creds.endpoints)
        let session = makeSession(pin: creds.pinSpki)
        let http = EngineHTTP(session: session, clientHeader: clientHeaderValue)
        let clock = self.clock
        let auth = AuthManager(store: store, http: http, endpoints: endpoints,
                               uptime: { TimeInterval(clock.monotonicMs()) / 1000 })
        chaos = ChaosUploader(session: session, restoring: restoring)
        return EngineController(
            db: db, library: library, uploader: chaos,
            client: ServerClient(endpoints: endpoints, auth: auth, http: http),
            settings: SettingsRepo(db: db), clock: clock, events: events,
            config: EngineConfig(stagingDir: dir.appendingPathComponent("staging"), chunkBytes: chunk))
    }

    private func item(_ id: String) throws -> Item { try XCTUnwrap(try db.item(localId: id), id) }

    #if canImport(Security)
    /// The Task 12 carry, run on macOS: `EngineHTTP` attaches a `MetricsObserver` as each task's
    /// delegate. Task-delegate methods it does not implement fall through to the session's
    /// `PinningDelegate`, so over real TLS a changed pin must still be refused and reported unsent,
    /// and the stored pin must still be accepted.
    func testRejectsChangedPinWithMetricsDelegateOverRealTLS() async throws {
        let server = try self.server
        let url = try XCTUnwrap(URL(string: "https://127.0.0.1:\(server.httpsPort)/api/v1/server/info"))
        let changed = String(repeating: "A", count: 43)

        let bad = EngineHTTP(session: makeSession(pin: changed), clientHeader: clientHeaderValue)
        XCTAssertTrue(bad.useTaskMetrics)
        do {
            _ = try await bad.send(URLRequest(url: url))
            XCTFail("a changed certificate must be refused")
        } catch let f as TransportFailure {
            XCTAssertEqual(f.pinRejectedHost, "127.0.0.1")
            XCTAssertEqual(f.sent, false)
            XCTAssertTrue(f.provablyUnsent)
            XCTAssertTrue(f.isTLS)
        }

        let good = EngineHTTP(session: makeSession(pin: server.pin), clientHeader: clientHeaderValue)
        let (_, resp) = try await good.send(URLRequest(url: url))
        XCTAssertEqual(resp.statusCode, 200)
    }
    #endif

    func testUploadsAndDedupes() async throws {
        let b = randomBytes(200_000, seed: 11)
        library.put("d1", b)
        library.put("d2", b)
        let c = controller()
        var runs = 0
        var report: RunReport
        repeat {
            report = await c.runOnce(budget: RunBudget())
            XCTAssertEqual(report.stop, .idle)
            runs += 1
            clock.advance(60 * 60 * 1000)
        } while report.nextAttemptAtMs != nil && runs < 5
        XCTAssertEqual(try item("d1").state, .backedUp)
        XCTAssertEqual(try item("d2").state, .backedUp)
        XCTAssertEqual(try item("d1").assetId, try item("d2").assetId)
        XCTAssertEqual(try server.assets(sha256: sha256Hex(b)).count, 1)
    }

    func testDropMidChunkResumes() async throws {
        let b = randomBytes(3 * 1024 * 1024 + 4321, seed: 12)
        library.put("big", b)
        let c = controller()
        chaos.dropPatch = 2
        chaos.sendBytes = 300_000
        _ = await c.runOnce(budget: RunBudget())
        let big = try item("big")
        XCTAssertEqual(big.state, .backedUp, "\(chaos.lines)")
        // The drop is resolved by HEAD (R2), which reports the bytes the server kept.
        let mib = 1 << 20
        let offsets = chaos.lines.filter { $0.hasPrefix("PATCH") }.compactMap { $0.components(separatedBy: "@").last }
        XCTAssertEqual(offsets, ["0", "\(mib)", "\(mib + 300_000)", "\(2 * mib + 300_000)"], "\(chaos.lines)")
        XCTAssertEqual(chaos.lines.filter { $0 == "POST /api/v1/uploads" }.count, 1)
        let assets = try server.assets(sha256: sha256Hex(b))
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first?["id"]?.stringValue, big.assetId)
    }

    /// Review Focus 1: killed mid-upload, relaunched after the session expired.
    func testResumeAfterSessionExpiry() async throws {
        let b = randomBytes(2 * 1024 * 1024 + 99, seed: 13)
        library.put("exp", b)
        let server = try self.server
        let c = controller()
        chaos.dropPatch = 2
        chaos.sendBytes = 0
        let terminated = Counter()
        // The session vanishes server-side (as on expiry) while the second chunk is in flight.
        chaos.beforeDrop = { req in
            for _ in 0..<50 {
                let (s, _) = (try? server.local("DELETE", req.url!.path)) ?? (0, nil)
                if s == 204 { terminated.next(); return }
                usleep(100_000)
            }
        }
        _ = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(terminated.value, 1, "tus termination")
        XCTAssertEqual(try item("exp").state, .backedUp)
        XCTAssertEqual(chaos.lines.filter { $0 == "POST /api/v1/uploads" }.count, 2, "a new session after the 404")
        XCTAssertEqual(try server.assets(sha256: sha256Hex(b)).count, 1)
    }

    func testTombstoneSkipsThenUndo() async throws {
        let b = randomBytes(50_000, seed: 14)
        let sha = sha256Hex(b)
        library.put("t1", b)
        let c = controller()
        _ = await c.runOnce(budget: RunBudget())
        let first = try XCTUnwrap(try item("t1").assetId)
        let server = try self.server
        XCTAssertEqual(try server.local("POST", "/api/v1/assets/trash", #"{"asset_ids":["\#(first)"]}"#).0, 200)
        XCTAssertEqual(try server.local("POST", "/api/v1/assets/purge", #"{"asset_ids":["\#(first)"]}"#).0, 200)

        library.put("t2", b)
        _ = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(try item("t2").state, .skipped)
        XCTAssertTrue(try server.assets(sha256: sha).isEmpty)

        let undone = await c.undoSkip(sha)
        XCTAssertTrue(undone)
        _ = await c.runOnce(budget: RunBudget())
        XCTAssertEqual(try item("t2").state, .backedUp)
        let again = try server.assets(sha256: sha)
        XCTAssertEqual(again.count, 1)
        XCTAssertNotEqual(again.first?["id"]?.stringValue, first)
        XCTAssertEqual(again.first?["id"]?.stringValue, try item("t2").assetId)
    }

    /// M§6: the run's budget ends while the OS still uploads a chunk; the app is relaunched and the
    /// new controller applies the completion and sends the last chunk itself.
    func testDetachedChunkCompletesThroughRelaunchedController() async throws {
        let mib = 1 << 20
        let b = randomBytes(2 * mib + 777, seed: 15)
        library.put("bg", b)
        let first = controller()
        chaos.hold = { r in r.httpMethod == "PATCH" && r.value(forHTTPHeaderField: "Upload-Offset") == "\(mib)" }
        let r1 = await first.runOnce(budget: RunBudget(maxDurationMs: 1500))
        XCTAssertEqual(r1.stop, .budget)
        let held = chaos.heldTasks
        XCTAssertEqual(held.count, 1)
        let desc = try XCTUnwrap(held.keys.first)
        XCTAssertEqual(try item("bg").state, .uploading)
        XCTAssertEqual(try item("bg").uploadOffset, Int64(mib))

        // Relaunch: a new controller whose session still runs that task.
        let second = controller(restoring: held)
        let relaunched = try XCTUnwrap(chaos)
        _ = await second.runOnce(budget: RunBudget())
        XCTAssertEqual(relaunched.lines, [], "nothing re-sent for the running task")
        try await relaunched.release(desc)
        let done = try await waitUntil(timeout: 30) { try self.item("bg").state == .backedUp }
        XCTAssertTrue(done, "\(relaunched.lines)")
        XCTAssertEqual(relaunched.lines.filter { $0.hasPrefix("PATCH") }.compactMap { $0.components(separatedBy: "@").last },
                       ["\(2 * mib)"])
        let assets = try server.assets(sha256: sha256Hex(b))
        XCTAssertEqual(assets.count, 1)
        XCTAssertEqual(assets.first?["id"]?.stringValue, try item("bg").assetId)
    }

    func testRefreshRotationSurvives() async throws {
        let c = controller()
        var tokens = [store.creds!.refreshToken]
        for round in 1...3 {
            library.put("r\(round)", randomBytes(10_000 + round, seed: UInt8(round)))
            // Past the access token's lifetime: the next request refreshes and rotates (P§6.2).
            clock.advance(15 * 60 * 1000)
            _ = await c.runOnce(budget: RunBudget())
            XCTAssertEqual(try item("r\(round)").state, .backedUp)
            tokens.append(store.creds!.refreshToken)
        }
        XCTAssertEqual(Set(tokens).count, tokens.count, "every refresh rotated the token: \(tokens)")
        XCTAssertEqual(store.wipes, 0)
        XCTAssertEqual(events.repairs, 0)
        // A restarted process starts from the stored (latest) token only.
        library.put("after-restart", randomBytes(777, seed: 99))
        _ = await controller().runOnce(budget: RunBudget())
        XCTAssertEqual(try item("after-restart").state, .backedUp)
        XCTAssertEqual(store.wipes, 0)
    }
}

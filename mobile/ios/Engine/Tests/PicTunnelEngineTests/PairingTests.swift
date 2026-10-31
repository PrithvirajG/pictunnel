import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import PicTunnelEngine

/// Pairing (P§6.3), the runtime that owns the engine per pairing, and ranged original downloads
/// (`saveToGallery`). HTTP runs through `StubProtocol`.
final class PairingTests: XCTestCase {
    private let sid = "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f"
    private let fp = "xKecCxNIWtM6GstVge3d62YGSu9rChlvCqOALKreFGc"

    private var qr: String {
        "pictunnel://pair?v=1&sid=\(sid)&code=K7Q2-M9XD-4T&fp=\(fp)"
            + "&u=https%3A%2F%2F192.168.1.20%3A8443&u=https%3A%2F%2Fphotos.example.com"
    }

    private func redeemBody(serverId: String? = nil) -> String {
        #"{"server_id":"\#(serverId ?? sid)","user":{"id":"u1","username":"ana","display_name":"Ana","role":"admin"},"#
            + #""device":{"id":"dev-1","name":"Ana's iPhone","platform":"ios","app_version":"0.1.0","created_at":"2026-10-03T12:00:00Z"},"#
            + #""tokens":\#(tokensJSON(0))}"#
    }

    /// A server: redeem, info, refresh, logout; everything else 404.
    private func installServer(redeem: StubReply? = nil, serverId: String? = nil, name: String = "Home server",
                               logouts: Counter = Counter()) {
        let body = redeemBody(serverId: serverId)
        let info = #"{"server_id":"\#(serverId ?? sid)","name":"\#(name)"}"#
        StubServer.shared.install { r in
            switch (r.method, r.path) {
            case ("POST", Pairer.redeemPath): return redeem ?? .json(201, body)
            case ("GET", "/healthz"): return .empty(200)
            case ("GET", "/api/v1/server/info"): return .json(200, info)
            case ("POST", "/api/v1/auth/refresh"): return .json(200, tokensJSON(1))
            case ("POST", "/api/v1/auth/logout"):
                logouts.next()
                return .empty(204)
            default: return .empty(404)
            }
        }
    }

    private func pairer(_ store: CredentialStore) -> Pairer {
        Pairer(store: store, appVersion: "0.1.0") { _ in stubHTTP() }
    }

    private func pairError(_ input: PairInput, store: CredentialStore = InMemoryCredentialStore()) async -> String? {
        do {
            _ = try await pairer(store).pair(input)
            return nil
        } catch let e as PairingError {
            return e.code
        } catch {
            return "unexpected \(error)"
        }
    }

    // MARK: - Pairer

    func testQrPairRedeemsAndStoresCredentials() async throws {
        installServer()
        let store = InMemoryCredentialStore()
        let paired = try await pairer(store).pair(PairInput(qrUri: qr, deviceName: "Ana's iPhone"))

        XCTAssertEqual(paired, Paired(serverId: sid, serverName: "Home server", userName: "ana", deviceId: "dev-1"))
        XCTAssertEqual(store.creds, Credentials(
            serverId: sid, endpoints: ["https://192.168.1.20:8443", "https://photos.example.com"], pinSpki: fp,
            refreshToken: "pt_rt_0", deviceId: "dev-1"))

        let redeem = try XCTUnwrap(StubServer.shared.requests.first { $0.path == Pairer.redeemPath })
        XCTAssertEqual(redeem.url.host, "192.168.1.20", "the LAN endpoint is tried first")
        XCTAssertEqual(redeem.header("PicTunnel-Client"), clientHeaderValue)
        XCTAssertNil(redeem.header("Authorization"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: redeem.body) as? [String: Any])
        XCTAssertEqual(json["code"] as? String, "K7Q2-M9XD-4T")
        let device = try XCTUnwrap(json["device"] as? [String: Any])
        XCTAssertEqual(device["device_name"] as? String, "Ana's iPhone")
        XCTAssertEqual(device["platform"] as? String, "ios")
        XCTAssertEqual(device["app_version"] as? String, "0.1.0")
    }

    func testManualPairPinsTheConfirmedFingerprint() async throws {
        installServer()
        let store = InMemoryCredentialStore()
        let paired = try await pairer(store).pair(PairInput(serverUrl: "https://photos.example.com", code: "k7q2-m9xd-4t",
                                                            deviceName: "Phone", pinnedFp: fp))
        XCTAssertEqual(paired.serverId, sid)
        XCTAssertEqual(store.creds?.endpoints, ["https://photos.example.com"])
        XCTAssertEqual(store.creds?.pinSpki, fp)
        let redeem = try XCTUnwrap(StubServer.shared.requests.first { $0.path == Pairer.redeemPath })
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: redeem.body) as? [String: Any])
        XCTAssertEqual(json["code"] as? String, "K7Q2-M9XD-4T", "the typed code is normalised to upper case")
    }

    func testPairErrorCodesTheAppExpects() async {
        // URI and input validation, before anything is sent.
        installServer()
        var code = await pairError(PairInput(qrUri: "https://example.com", deviceName: "p"))
        XCTAssertEqual(code, "invalid_scheme")
        code = await pairError(PairInput(serverUrl: "http://192.168.1.20:8443", code: "K7Q2-M9XD-4T", deviceName: "p", pinnedFp: fp))
        XCTAssertEqual(code, "insecure_endpoint")
        code = await pairError(PairInput(serverUrl: "https://h.example", code: "K7Q2", deviceName: "p", pinnedFp: fp))
        XCTAssertEqual(code, "invalid_code")
        code = await pairError(PairInput(serverUrl: "https://h.example", code: "K7Q2-M9XD-4T", deviceName: "p"))
        XCTAssertEqual(code, "missing_fingerprint")
        XCTAssertTrue(StubServer.shared.requests.isEmpty, "invalid input sends nothing")

        // Server problems keep their code.
        installServer(redeem: .problem(400, "pairing_code_invalid"))
        code = await pairError(PairInput(qrUri: qr, deviceName: "p"))
        XCTAssertEqual(code, "pairing_code_invalid")
        installServer(redeem: .problem(429, "rate_limited"))
        code = await pairError(PairInput(qrUri: qr, deviceName: "p"))
        XCTAssertEqual(code, "rate_limited")

        // Transport.
        StubServer.shared.install { _ in .error(.cannotConnectToHost) }
        code = await pairError(PairInput(qrUri: qr, deviceName: "p"))
        XCTAssertEqual(code, PairingError.unreachable)
        StubServer.shared.install { _ in .error(.notConnectedToInternet) }
        code = await pairError(PairInput(qrUri: qr, deviceName: "p"))
        XCTAssertEqual(code, PairingError.offline)
        StubServer.shared.install { r in r.url.host == "192.168.1.20" ? .error(.serverCertificateUntrusted) : .error(.cannotConnectToHost) }
        code = await pairError(PairInput(qrUri: qr, deviceName: "p"))
        XCTAssertEqual(code, PairingError.pinMismatch)
        XCTAssertEqual(Pairer.transportError(TransportFailure(code: .cancelled, sent: false, pinRejectedHost: "h")).code,
                       PairingError.pinMismatch)

        // A different server answered than the QR code named: nothing is stored.
        installServer(serverId: "01928f3e-0000-7000-8000-000000000bad")
        let store = InMemoryCredentialStore()
        code = await pairError(PairInput(qrUri: qr, deviceName: "p"), store: store)
        XCTAssertEqual(code, PairingError.serverIdMismatch)
        XCTAssertNil(store.creds)
    }

    // MARK: - runtime

    private func runtime(store: InMemoryCredentialStore, db: EngineDB, events: RecordingEvents = RecordingEvents(),
                         staging: URL? = nil) throws -> EngineRuntime {
        let dir = staging ?? FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return EngineRuntime(store: store, library: FakeLibrary(), uploader: FakeUploader(), events: events, db: db,
                             config: EngineConfig(stagingDir: dir), appVersion: "0.1.0", clock: FakeClock(),
                             pinning: PinningDelegate(store: store)) { _ in stubHTTP() }
    }

    func testRuntimePairConnectionAndUnpair() async throws {
        let logouts = Counter()
        installServer(logouts: logouts)
        let store = InMemoryCredentialStore()
        let db = try EngineDB.inMemory()
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString)")
        let rt = try runtime(store: store, db: db, staging: staging)
        XCTAssertFalse(rt.isPaired)
        XCTAssertNil(rt.connection())

        _ = try await rt.pair(PairInput(qrUri: qr, deviceName: "p"))
        XCTAssertTrue(rt.isPaired)
        let conn = try XCTUnwrap(rt.connection())
        XCTAssertEqual(conn, RuntimeConnection(serverId: sid, name: "Home server", activeEndpoint: "https://192.168.1.20:8443",
                                               onLan: true, fp16: String(fp.prefix(16)), fpFull: fp))
        let token = try await rt.accessToken()
        XCTAssertEqual(token, "pt_at_1")

        try db.upsert(Item(localId: "a", size: 1, modifiedAtMs: 1, takenAtMs: 1, mime: "image/jpeg", kind: .photo, filename: "a.jpg"))
        try Data("x".utf8).write(to: staging.appendingPathComponent("a-primary"))
        await rt.unpair()
        XCTAssertEqual(logouts.value, 1, "unpair revokes the session on the server, best effort")
        XCTAssertNil(store.creds)
        XCTAssertFalse(rt.isPaired)
        XCTAssertNil(try db.item(localId: "a"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testPairingAnotherServerStartsTheIndexOver() async throws {
        installServer()
        let store = InMemoryCredentialStore()
        let db = try EngineDB.inMemory()
        let rt = try runtime(store: store, db: db)
        _ = try await rt.pair(PairInput(qrUri: qr, deviceName: "p"))
        try db.upsert(Item(localId: "a", size: 1, modifiedAtMs: 1, takenAtMs: 1, mime: "image/jpeg", kind: .photo,
                           filename: "a.jpg", state: .backedUp, assetId: "x"))

        // The same server again (after a repair, say): the index stays.
        try store.wipe()
        _ = try await rt.pair(PairInput(qrUri: qr, deviceName: "p"))
        XCTAssertEqual(try db.item(localId: "a")?.state, .backedUp)

        // Another server: what was backed up there says nothing here.
        let other = "01928f3e-0000-7000-8000-0000000000b2"
        installServer(serverId: other)
        let qr2 = qr.replacingOccurrences(of: sid, with: other)
        _ = try await rt.pair(PairInput(qrUri: qr2, deviceName: "p"))
        XCTAssertNil(try db.item(localId: "a"))
        XCTAssertEqual(rt.connection()?.serverId, other)
    }

    func testRepairFiresOnceAndDropsTheEngine() async throws {
        StubServer.shared.install { r in
            r.path == "/api/v1/auth/refresh" ? .problem(401, "refresh_token_reused") : .empty(404)
        }
        let store = InMemoryCredentialStore(testCredentials())
        let events = RecordingEvents()
        let rt = try runtime(store: store, db: try EngineDB.inMemory(), events: events)
        XCTAssertTrue(rt.isPaired)
        do {
            _ = try await rt.accessToken()
            XCTFail("expected needsRepair")
        } catch {
            XCTAssertEqual(error as? RuntimeError, .needsRepair)
        }
        XCTAssertEqual(events.repairs, 1)
        XCTAssertFalse(rt.isPaired)
        do {
            _ = try await rt.accessToken()
            XCTFail("expected notPaired")
        } catch {
            XCTAssertEqual(error as? RuntimeError, .notPaired)
        }
        XCTAssertEqual(events.repairs, 1, "fires once per pairing")
    }

    func testRunBlockerSkipsTheRun() async throws {
        installServer()
        let store = InMemoryCredentialStore(testCredentials())
        let rt = try runtime(store: store, db: try EngineDB.inMemory())
        let finished = Counter()
        rt.onRunFinished = { _ in finished.next() }
        rt.runBlocker = { s in s.wifiOnly ? .wifiRequired : nil }
        var s = EngineSettings()
        s.wifiOnly = true
        try await rt.controller()!.setSettings(s)
        let blocked = await rt.runOnce(budget: RunBudget())
        XCTAssertNil(blocked)
        XCTAssertEqual(finished.value, 0)
        s.wifiOnly = false
        try await rt.controller()!.setSettings(s)
        let report = await rt.runOnce(budget: RunBudget())
        XCTAssertEqual(report?.stop, .idle)
        XCTAssertEqual(finished.value, 1)
    }

    // MARK: - originals

    func testDownloadOriginalInRanges() async throws {
        let content = counterBytes(length: 20, seed: 3)
        StubServer.shared.install { r in
            if r.path == "/api/v1/auth/refresh" { return .json(200, tokensJSON(1)) }
            guard r.path == "/api/v1/assets/a1/original", let range = r.header("Range") else { return .empty(404) }
            let spec = range.dropFirst("bytes=".count).split(separator: "-")
            let start = Int(spec[0])!, end = min(Int(spec[1])!, content.count - 1)
            return .http(206, ["Content-Range": "bytes \(start)-\(end)/\(content.count)", "ETag": "\"abc\""],
                         content.subdata(in: start..<(end + 1)))
        }
        let store = InMemoryCredentialStore(testCredentials())
        let endpoints = Endpoints(store.creds!.endpoints)
        let client = ServerClient(endpoints: endpoints, auth: AuthManager(store: store, http: stubHTTP(), endpoints: endpoints),
                                  http: stubHTTP())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }

        let n = try await client.downloadOriginal(assetId: "a1", to: file, chunkBytes: 8)
        XCTAssertEqual(n, 20)
        XCTAssertEqual(try Data(contentsOf: file), content)
        let gets = StubServer.shared.requests.filter { $0.path.hasSuffix("/original") }
        XCTAssertEqual(gets.map { $0.header("Range") }, ["bytes=0-7", "bytes=8-15", "bytes=16-23"])
        XCTAssertEqual(gets.map { $0.header("If-Range") }, [nil, "\"abc\"", "\"abc\""])
        XCTAssertTrue(gets.allSatisfy { $0.header("Authorization") == "Bearer pt_at_1" })

        // A server that ignores ranges sends the whole file at once.
        StubServer.shared.install { r in
            r.path == "/api/v1/auth/refresh" ? .json(200, tokensJSON(2)) : .http(200, [:], content)
        }
        let m = try await client.downloadOriginal(assetId: "a1", to: file, chunkBytes: 8)
        XCTAssertEqual(m, 20)
        XCTAssertEqual(try Data(contentsOf: file), content)

        StubServer.shared.install { r in
            r.path == "/api/v1/auth/refresh" ? .json(200, tokensJSON(3)) : .problem(404, "not_found")
        }
        do {
            _ = try await client.downloadOriginal(assetId: "a1", to: file)
            XCTFail("expected an error")
        } catch let e as DownloadError {
            XCTAssertEqual(e.code, "not_found")
        }
    }

    func testContentRangeParsing() {
        XCTAssertEqual(ServerClient.contentRange("bytes 8-15/20")?.start, 8)
        XCTAssertEqual(ServerClient.contentRange("bytes 8-15/20")?.total, 20)
        XCTAssertNil(ServerClient.contentRange("bytes 8-15/*")?.total)
        XCTAssertNil(ServerClient.contentRange("items 1-2/3"))
        XCTAssertNil(ServerClient.contentRange(nil))
    }
}

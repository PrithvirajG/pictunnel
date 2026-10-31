import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
import XCTest
@testable import PicTunnelEngine

/// The iOS engine network layer (M§4.2–M§4.4), mirroring the Kotlin `net` tests (Task 7).
/// HTTP runs through `StubProtocol`; SecTrust pinning runs on Apple platforms only.
final class NetTests: XCTestCase {
    private let base = "https://pictunnel.test"
    private let sha = "fbbab289f7f94b25736c58be46a994c441fd02552cc6022352e3d86d2fab7c83"

    private let serverInfoBody = """
        {"server_id":"01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f","name":"Home server","version":"0.1.0","api_version":"1.0",
         "min_client_version":{"android":"0.1.0","ios":"0.1.0","web":"0.1.0"},"capabilities":["tus"],
         "upload":{"tus_version":"1.0.0","max_file_bytes":53687091200,"recommended_chunk_bytes":8388608},
         "time":"2026-10-03T12:00:00Z","future_field":1}
        """

    private let checkBody = """
        {"results":[
          {"sha256":"fbbab289","verdict":"exists","asset_id":"01928f40-0000-7000-8000-000000000001","asset_state":"active","has_live_video":false,"on_disk":true},
          {"sha256":"18af9b05","verdict":"missing"},
          {"sha256":"f6dd7fec","verdict":"partial","upload":{"id":"u1","url":"/api/v1/uploads/u1","offset":1048576,"length":3145728,"expires_at":"2026-10-04T12:00:00Z"}},
          {"sha256":"aaaa","verdict":"tombstoned","deleted_at":"2026-10-01T00:00:00Z"},
          {"sha256":"bbbb","verdict":"brand_new_verdict"}]}
        """

    private struct Stack {
        let api: ServerClient
        let auth: AuthManager
        let store: InMemoryCredentialStore
        let endpoints: Endpoints
        let refreshes: Counter
    }

    /// Serves `/auth/refresh` with a fresh token pair each time and delegates the rest to `rest`.
    private func stack(endpoints urls: [String]? = nil,
                       _ rest: @escaping @Sendable (Recorded) -> StubReply) -> Stack {
        let refreshes = Counter()
        StubServer.shared.install { r in
            r.path == "/api/v1/auth/refresh" ? .json(200, tokensJSON(refreshes.next())) : rest(r)
        }
        let store = InMemoryCredentialStore(testCredentials(urls ?? [base]))
        let endpoints = Endpoints(store.creds!.endpoints)
        let http = stubHTTP()
        let auth = AuthManager(store: store, http: http, endpoints: endpoints)
        return Stack(api: ServerClient(endpoints: endpoints, auth: auth, http: http),
                     auth: auth, store: store, endpoints: endpoints, refreshes: refreshes)
    }

    // MARK: - tus builders

    func testMetadataEncoding() {
        // P§11.5 golden: sha256, filename IMG_0001.JPG, mime image/jpeg, local_id a-1.
        let meta = UploadMeta(sha256: sha, filename: "IMG_0001.JPG", mime: "image/jpeg", localId: "a-1")
        XCTAssertEqual(
            TusRequests.encodeMetadata(meta),
            "sha256 ZmJiYWIyODlmN2Y5NGIyNTczNmM1OGJlNDZhOTk0YzQ0MWZkMDI1NTJjYzYwMjIzNTJlM2Q4NmQyZmFiN2M4Mw==,"
                + "filename SU1HXzAwMDEuSlBH,mime aW1hZ2UvanBlZw==,local_id YS0x"
        )
        let full = UploadMeta(sha256: "ab", filename: "é.mov", mime: "video/quicktime",
                              pairRole: "live_video", pairSha256: "cd", overrideTombstone: true)
        XCTAssertEqual(
            TusRequests.encodeMetadata(full),
            "sha256 YWI=,filename w6kubW92,mime dmlkZW8vcXVpY2t0aW1l,pair_role bGl2ZV92aWRlbw==,pair_sha256 Y2Q=,override_tombstone MQ=="
        )
        let dated = UploadMeta(sha256: "ab", filename: "a", mime: "m", localId: "l", createdAt: "c",
                               modifiedAt: "d", stackKey: "s")
        XCTAssertEqual(TusRequests.encodeMetadata(dated),
                       "sha256 YWI=,filename YQ==,mime bQ==,local_id bA==,created_at Yw==,modified_at ZA==,stack_key cw==")
    }

    func testTusRequestBuilders() throws {
        let baseURL = URL(string: "https://192.168.1.10:8443")!
        let meta = UploadMeta(sha256: sha, filename: "IMG_0001.JPG", mime: "image/jpeg")

        let single = TusRequests.create(base: baseURL, meta: meta, length: 1000, bodyFile: URL(fileURLWithPath: "/tmp/x"))
        XCTAssertEqual(single.httpMethod, "POST")
        XCTAssertEqual(single.url?.absoluteString, "https://192.168.1.10:8443/api/v1/uploads")
        XCTAssertEqual(single.value(forHTTPHeaderField: "Tus-Resumable"), "1.0.0")
        XCTAssertEqual(single.value(forHTTPHeaderField: "Upload-Length"), "1000")
        XCTAssertEqual(single.value(forHTTPHeaderField: "Upload-Metadata"), TusRequests.encodeMetadata(meta))
        XCTAssertEqual(single.value(forHTTPHeaderField: "Content-Type"), "application/offset+octet-stream")
        XCTAssertNil(single.httpBody, "the body comes from the file via uploadTask(with:fromFile:)")

        let bodyless = TusRequests.create(base: baseURL, meta: meta, length: 70_000_000, bodyFile: nil)
        XCTAssertNil(bodyless.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(bodyless.value(forHTTPHeaderField: "Upload-Length"), "70000000")

        let session = URL(string: "https://192.168.1.10:8443/api/v1/uploads/u1")!
        let head = TusRequests.head(session)
        XCTAssertEqual(head.httpMethod, "HEAD")
        XCTAssertEqual(head.url, session)
        XCTAssertEqual(head.value(forHTTPHeaderField: "Tus-Resumable"), "1.0.0")

        let patch = TusRequests.patch(session, offset: 67_108_864)
        XCTAssertEqual(patch.httpMethod, "PATCH")
        XCTAssertEqual(patch.value(forHTTPHeaderField: "Upload-Offset"), "67108864")
        XCTAssertEqual(patch.value(forHTTPHeaderField: "Content-Type"), "application/offset+octet-stream")
        XCTAssertEqual(patch.value(forHTTPHeaderField: "Tus-Resumable"), "1.0.0")

        let del = TusRequests.terminate(session)
        XCTAssertEqual(del.httpMethod, "DELETE")
        XCTAssertEqual(del.value(forHTTPHeaderField: "Tus-Resumable"), "1.0.0")

        // Background tasks carry the client header and bearer token like every engine request.
        let authed = TusRequests.authorize(patch, accessToken: "pt_at_9", clientHeader: clientHeaderValue)
        XCTAssertEqual(authed.value(forHTTPHeaderField: "Authorization"), "Bearer pt_at_9")
        XCTAssertEqual(authed.value(forHTTPHeaderField: "PicTunnel-Client"), clientHeaderValue)
    }

    func testTusResponseParsing() throws {
        let baseURL = URL(string: "https://192.168.1.10:8443")!
        let created = ServerOutcome(status: 201, headers: [
            "Location": "/api/v1/uploads/01928f40-2222-7aaa-8bbb-0123456789ab",
            "upload-offset": "1000",
            "PicTunnel-Asset-Id": "01928f40-0000-7000-8000-000000000001",
            "PicTunnel-Asset-Created": "true",
            "Upload-Expires": "Sun, 04 Oct 2026 12:00:00 GMT",
        ])
        let c = try XCTUnwrap(TusCreated(created, base: baseURL))
        XCTAssertEqual(c.url.absoluteString, "https://192.168.1.10:8443/api/v1/uploads/01928f40-2222-7aaa-8bbb-0123456789ab")
        XCTAssertEqual(c.offset, 1000)
        XCTAssertEqual(c.assetId, "01928f40-0000-7000-8000-000000000001")
        XCTAssertEqual(c.assetCreated, true)
        XCTAssertEqual(c.expires, "Sun, 04 Oct 2026 12:00:00 GMT")
        // decide() takes it straight to BackedUp (R4).
        let d = Decide.decide(Given(flow: .backup, itemState: .uploading, lastAction: .createUpload,
                                    item: ItemFlags(hasUploadId: false)), created)
        XCTAssertEqual(d.action, .markBackedUp)

        let bare = try XCTUnwrap(TusCreated(ServerOutcome(status: 201, headers: ["Location": "/api/v1/uploads/x"]), base: baseURL))
        XCTAssertEqual(bare.offset, 0)
        XCTAssertNil(bare.assetId)
        XCTAssertNil(TusCreated(ServerOutcome(status: 201), base: baseURL), "no Location, no session")
        XCTAssertNil(TusCreated(ServerOutcome(status: 409), base: baseURL))

        let head = try XCTUnwrap(TusHead(ServerOutcome(status: 200, headers: [
            "Upload-Offset": "524288", "Upload-Length": "1048576", "Upload-Expires": "Sun, 04 Oct 2026 12:00:00 GMT",
        ])))
        XCTAssertEqual(head, TusHead(offset: 524288, length: 1048576, expires: "Sun, 04 Oct 2026 12:00:00 GMT", assetId: nil))

        let patched = try XCTUnwrap(TusPatched(ServerOutcome(status: 204, headers: [
            "Upload-Offset": "1048576", "PicTunnel-Asset-Id": "a1", "PicTunnel-Asset-Created": "false",
        ])))
        XCTAssertEqual(patched, TusPatched(offset: 1048576, assetId: "a1", assetCreated: false))

        // 409 offset_mismatch carries the server's offset; decide() asks HEAD.
        let mismatch = ServerOutcome(status: 409, headers: ["Upload-Offset": "524288"],
                                     body: .object(["code": .string("offset_mismatch")]))
        XCTAssertEqual(mismatch.uploadOffset, 524288)
        XCTAssertNil(TusPatched(mismatch))
        XCTAssertEqual(Decide.decide(Given(flow: .backup, itemState: .uploading, lastAction: .appendUpload,
                                           item: ItemFlags(hasUploadId: true)), mismatch).action, .headThenResume)
    }

    // MARK: - chunk slicer

    func testChunkSlicerExactBytes() throws {
        // Payload C (P§10.1): counter pattern, seed 0, 3 MiB.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slicer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let length = 3_145_728
        let payload = counterBytes(length: length)
        let source = dir.appendingPathComponent("item-1-primary")
        try payload.write(to: source)
        XCTAssertEqual(sha256Hex(payload), "f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0")

        XCTAssertEqual(ChunkSlicer.chunkBytes, 67_108_864, "iOS chunks are 64 MiB")
        let slicer = ChunkSlicer(bufferSize: 100_000) // odd buffer so reads straddle chunk boundaries

        // An unaligned slice in the middle.
        let mid = try slicer.slice(source: source, offset: 1_048_583, length: 1_000_001, into: dir)
        XCTAssertEqual(try Data(contentsOf: mid), counterBytes(length: 1_000_001, start: 1_048_583))

        // 1 MiB chunks reassemble to exactly C; the last one is clamped to the end of the file.
        var joined = Data()
        var files: [URL] = []
        for off in stride(from: 0, to: length + 1, by: 1_200_000) where off < length {
            let f = try slicer.slice(source: source, offset: Int64(off), length: 1_200_000, into: dir)
            files.append(f)
            joined.append(try Data(contentsOf: f))
        }
        XCTAssertEqual(Set(files).count, 3, "each slice gets its own file")
        XCTAssertEqual(try Data(contentsOf: files[2]).count, length - 2_400_000)
        XCTAssertEqual(joined, payload)
        XCTAssertEqual(sha256Hex(joined), "f6dd7fec8584ad00219a447071c1fa368a1caee4d9c146083d233713ddccd2c0")

        // Re-slicing the same range replaces the previous slice file.
        let again = try slicer.slice(source: source, offset: 1_048_583, length: 10, into: dir)
        XCTAssertEqual(again, mid)
        XCTAssertEqual(try Data(contentsOf: again), counterBytes(length: 10, start: 1_048_583))

        XCTAssertThrowsError(try slicer.slice(source: source, offset: Int64(length), length: 1, into: dir))
        XCTAssertThrowsError(try slicer.slice(source: source, offset: -1, length: 1, into: dir))
        XCTAssertThrowsError(try slicer.slice(source: source, offset: 0, length: 0, into: dir))
    }

    // MARK: - auth

    func testRefreshSingleFlight() async throws {
        let refreshes = Counter()
        StubServer.shared.install { r in
            if r.path == "/api/v1/auth/refresh" {
                Thread.sleep(forTimeInterval: 0.15) // keep the refresh in flight while the others pile up
                return .json(200, tokensJSON(refreshes.next()))
            }
            return r.header("Authorization") == "Bearer pt_at_2"
                ? .json(200, #"{"results":[{"sha256":"aa","verdict":"missing"}]}"#)
                : .problem(401, "token_expired")
        }
        let store = InMemoryCredentialStore(testCredentials([base]))
        let endpoints = Endpoints([base])
        let http = stubHTTP()
        let auth = AuthManager(store: store, http: http, endpoints: endpoints)
        let api = ServerClient(endpoints: endpoints, auth: auth, http: http)

        let warm = try await auth.accessToken()
        XCTAssertEqual(warm, "pt_at_1", "pt_at_1 is the token the server now rejects")
        XCTAssertEqual(refreshes.value, 1)

        let results = await withTaskGroup(of: Outcome<[CheckResult]>.self) { group in
            for _ in 0..<10 { group.addTask { await api.check([CheckItem(sha256: "aa", sizeBytes: 1)]) } }
            var all: [Outcome<[CheckResult]>] = []
            for await r in group { all.append(r) }
            return all
        }

        XCTAssertEqual(refreshes.value, 2, "10 concurrent 401s cause exactly one refresh")
        XCTAssertEqual(results.count, 10)
        for r in results {
            guard case let .ok(value, _) = r else { return XCTFail("expected ok, got \(r)") }
            XCTAssertEqual(value.map(\.verdict), ["missing"])
        }
        XCTAssertEqual(store.creds?.refreshToken, "pt_rt_2", "the rotated refresh token is persisted")
        let bodies = StubServer.shared.requests.filter { $0.path == "/api/v1/auth/refresh" }
            .map { String(decoding: $0.body, as: UTF8.self) }
        XCTAssertEqual(bodies, [#"{"refresh_token":"pt_rt_0"}"#, #"{"refresh_token":"pt_rt_1"}"#])
    }

    func testRefreshReusedWipes() async throws {
        StubServer.shared.install { _ in .problem(401, "refresh_token_reused") }
        let store = InMemoryCredentialStore(testCredentials([base]))
        let repairs = Counter()
        let auth = AuthManager(store: store, http: stubHTTP(),
                               endpoints: Endpoints([base]), onNeedsRepair: { repairs.next() })

        let out = await auth.onUnauthorized()
        guard case let .needsRepair(raw) = out else { return XCTFail("expected needsRepair, got \(out)") }
        XCTAssertEqual(raw?.problem?.code, "refresh_token_reused")
        XCTAssertEqual(store.wipes, 1)
        XCTAssertNil(store.creds)
        XCTAssertEqual(repairs.value, 1)

        // Later requests fail as require-repair without touching the network again.
        let before = StubServer.shared.requests.count
        do {
            _ = try await auth.accessToken()
            XCTFail("expected AuthError.needsRepair")
        } catch AuthError.needsRepair {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(StubServer.shared.requests.count, before)

        // The engine sees the same thing through ServerClient, mapped by decide() to require_repair.
        let api = ServerClient(endpoints: Endpoints([base]), auth: auth,
                               http: stubHTTP())
        let check = await api.check([CheckItem(sha256: "aa", sizeBytes: 1)])
        guard case let .fail(failRaw, failure) = check else { return XCTFail("expected fail") }
        XCTAssertEqual(failure, .needsRepair)
        XCTAssertEqual(Decide.decide(Given(flow: .backup, itemState: .hashed, lastAction: .check), failRaw).action,
                       .requireRepair)
        XCTAssertEqual(StubServer.shared.requests.count, before)
    }

    func testRefreshNetworkFailureKeepsTokens() async throws {
        StubServer.shared.install { _ in .error(.notConnectedToInternet) }
        let store = InMemoryCredentialStore(testCredentials([base]))
        let auth = AuthManager(store: store, http: stubHTTP(),
                               endpoints: Endpoints([base]))
        let out = await auth.onUnauthorized()
        guard case let .transient(raw) = out else { return XCTFail("expected transient, got \(out)") }
        XCTAssertEqual(raw.transport, .offline)
        XCTAssertEqual(store.wipes, 0)
        XCTAssertEqual(store.creds?.refreshToken, "pt_rt_0")
    }

    // MARK: - endpoints

    func testEndpointFallback() async throws {
        let lan = "https://192.168.77.1:8443"
        let remote = "https://photos.example.com"
        StubServer.shared.install { r in
            r.url.host == "192.168.77.1" ? .error(.timedOut) : .json(200, "{}")
        }
        let endpoints = Endpoints([lan, remote])
        XCTAssertEqual(endpoints.active.host, "192.168.77.1", "LAN is preferred first")
        let http = stubHTTP()

        let (_, resp) = try await endpoints.execute(http, path: "/api/v1/server/info") { URLRequest(url: $0) }
        XCTAssertEqual(resp.statusCode, 200)
        let first = StubServer.shared.requests
        let lanTries = first.filter { $0.url.host == "192.168.77.1" }
        XCTAssertFalse(lanTries.isEmpty)
        for t in lanTries { XCTAssertEqual(t.timeout, 3, "LAN connect timeout is 3 s") }
        XCTAssertEqual(endpoints.active.host, "photos.example.com", "the remote endpoint is now active")
        XCTAssertEqual(first.last?.url.absoluteString, "https://photos.example.com/api/v1/server/info")
        XCTAssertEqual(first.last?.header("PicTunnel-Client"), clientHeaderValue)

        // The next request goes straight to the active endpoint.
        _ = try await endpoints.execute(http, path: "/api/v1/server/info") { URLRequest(url: $0) }
        XCTAssertEqual(StubServer.shared.requests.filter { $0.url.host == "192.168.77.1" }.count, lanTries.count)

        // Back to stored order after a network change.
        endpoints.resetToPreferred()
        XCTAssertEqual(endpoints.active.host, "192.168.77.1")
    }

    /// A follow-up chunk handed straight to the upload session (after a relaunch) must not go to an
    /// unproven LAN endpoint: the active endpoint is settled first, and only once.
    func testEnsureActiveReachedProbesAndFallsBackOnce() async throws {
        StubServer.shared.install { r in
            r.url.host == "192.168.77.1" ? .error(.cannotConnectToHost) : .json(200, "{}")
        }
        let endpoints = Endpoints(["https://192.168.77.1:8443", "https://photos.example.com"])
        let http = stubHTTP()
        try await endpoints.ensureActiveReached(http)
        XCTAssertEqual(endpoints.active.host, "photos.example.com")
        let count = StubServer.shared.requests.count
        XCTAssertTrue(StubServer.shared.requests.contains { $0.path == Endpoints.probePath && $0.url.host == "photos.example.com" })
        try await endpoints.ensureActiveReached(http)
        XCTAssertEqual(StubServer.shared.requests.count, count, "a reached endpoint needs no new probe")
    }

    func testReachableLanIsUsedDirectly() async throws {
        StubServer.shared.install { _ in .json(200, "{}") }
        let endpoints = Endpoints(["https://192.168.77.1:8443", "https://photos.example.com"])
        let http = stubHTTP()
        _ = try await endpoints.execute(http, path: "/api/v1/sync/check") { URLRequest(url: $0) }
        _ = try await endpoints.execute(http, path: "/api/v1/sync/check") { URLRequest(url: $0) }
        let reqs = StubServer.shared.requests
        XCTAssertTrue(reqs.allSatisfy { $0.url.host == "192.168.77.1" })
        let real = reqs.filter { $0.path == "/api/v1/sync/check" }
        XCTAssertEqual(real.count, 2)
        for r in real { XCTAssertGreaterThan(r.timeout, 3, "only reaching the LAN is held to 3 s") }
    }

    func testAllUnreachableIsOffline() async throws {
        StubServer.shared.install { _ in .error(.cannotConnectToHost) }
        let endpoints = Endpoints(["https://192.168.77.1:8443", "https://photos.example.com"])
        let http = stubHTTP()
        do {
            _ = try await endpoints.execute(http, path: "/x") { URLRequest(url: $0) }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(Transport.classify(error), .offline)
        }
    }

    func testAmbiguousTimeoutOnConfirmedEndpointDoesNotFallBack() async throws {
        let calls = Counter()
        StubServer.shared.install { r in
            if r.url.host == "photos.example.com" { return .json(200, "{}") }
            return calls.next() <= 2 ? .json(200, "{}") : .error(.timedOut)
        }
        let endpoints = Endpoints(["https://192.168.77.1:8443", "https://photos.example.com"])
        let http = stubHTTP()
        _ = try await endpoints.execute(http, path: "/api/v1/sync/check") { URLRequest(url: $0) }
        do {
            _ = try await endpoints.execute(http, path: "/api/v1/sync/check") { URLRequest(url: $0) }
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(Transport.classify(error), .timeout, "R2: the outcome is unknown, so it is not retried elsewhere")
        }
        XCTAssertFalse(StubServer.shared.requests.contains { $0.url.host == "photos.example.com" })
    }

    func testLanClassification() {
        for h in ["192.168.1.10", "10.0.0.2", "172.20.1.1", "169.254.3.4", "nas.local", "nas", "fd00::1", "[fe80::1]", "127.0.0.1"] {
            XCTAssertTrue(Endpoints.isLan(h), h)
        }
        for h in ["photos.example.com", "8.8.8.8", "172.32.0.1", "2001:db8::1", "[2001:db8::1]"] {
            XCTAssertFalse(Endpoints.isLan(h), h)
        }
    }

    func testRelativeAndAbsoluteTargets() {
        let endpoints = Endpoints(["https://192.168.1.10:8443", "https://photos.example.com"])
        XCTAssertEqual(endpoints.relativize("https://photos.example.com/api/v1/uploads/x"), "/api/v1/uploads/x")
        XCTAssertEqual(endpoints.relativize("https://192.168.1.10:8443/api/v1/uploads/x?a=1"), "/api/v1/uploads/x?a=1")
        XCTAssertEqual(endpoints.relativize("/api/v1/uploads/x"), "/api/v1/uploads/x")
        XCTAssertNil(endpoints.relativize("https://elsewhere.example/api/v1/uploads/x"))
        XCTAssertEqual(endpoints.relativize("https://photos.example.com/api/v1/uploads/a%2Fb?x=%20y"),
                       "/api/v1/uploads/a%2Fb?x=%20y", "percent-encoding is kept")
        XCTAssertEqual(endpoints.resolve("/api/v1/uploads/x")?.absoluteString, "https://192.168.1.10:8443/api/v1/uploads/x")
    }

    func testLanThatNeverAnswersFallsBackToRemoteWithinConnectBound() async throws {
        // The LAN endpoint is a real loopback port that never answers (not stubbed).
        let silent = try SilentListener()
        StubServer.shared.install { _ in .json(200, "{}") }
        let endpoints = Endpoints(["http://127.0.0.1:\(silent.port)", "https://photos.example.com"])
        let started = Date()
        let (_, resp) = try await endpoints.execute(stubHTTP(), path: "/api/v1/sync/check") { URLRequest(url: $0) }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(endpoints.active.host, "photos.example.com")
        XCTAssertGreaterThanOrEqual(elapsed, 2.5, "the LAN got its 3 s")
        XCTAssertLessThan(elapsed, 5, "but no more")
        XCTAssertEqual(StubServer.shared.requests.map { $0.path }, ["/api/v1/sync/check"])
    }

    func testCancellationCancelsRequestAndNeverFallsBack() async throws {
        StubServer.shared.install { r in
            if r.url.host == "first.example" {
                Thread.sleep(forTimeInterval: 1.5)
                return .error(.cannotConnectToHost) // would be a fallback reason if not cancelled
            }
            return .json(200, "{}")
        }
        let endpoints = Endpoints(["https://first.example", "https://second.example"])
        let http = stubHTTP()
        let started = Date()
        let task = Task { try await endpoints.execute(http, path: "/api/v1/sync/check") { URLRequest(url: $0) } }
        while StubServer.shared.requests.isEmpty, Date().timeIntervalSince(started) < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        task.cancel()
        let result = await task.result
        let elapsed = Date().timeIntervalSince(started)
        guard case let .failure(error) = result else { return XCTFail("expected a failure") }
        XCTAssertLessThan(elapsed, 1.4, "the request was cancelled, not waited out")
        XCTAssertEqual(Transport.classify(error), .reset)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(StubServer.shared.requests.contains { $0.url.host == "second.example" },
                       "a cancelled request is never replayed on another endpoint")
    }

    func testTlsFailureOnEveryEndpointIsTls() async throws {
        StubServer.shared.install { r in
            r.url.host == "192.168.77.1" ? .error(.serverCertificateUntrusted) : .error(.cannotConnectToHost)
        }
        let endpoints = Endpoints(["https://192.168.77.1:8443", "https://photos.example.com"])
        do {
            _ = try await endpoints.execute(stubHTTP(), path: "/x") { URLRequest(url: $0) }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(Transport.classify(error), .tls, "mixed tls + unreachable is tls")
            XCTAssertEqual(ServerClient.failure(error), .tlsRejected(host: "192.168.77.1"))
        }
        // Pin rejection is classified from the delegate's per-task record, not URLError.cancelled.
        XCTAssertEqual(Transport.classify(TransportFailure(code: .cancelled, pinRejectedHost: "h")), .tls)
        XCTAssertTrue(TransportFailure(code: .cancelled, pinRejectedHost: "h").provablyUnsent)
        XCTAssertFalse(TransportFailure(code: .cancelled).provablyUnsent)
        XCTAssertFalse(TransportFailure(code: .cannotConnectToHost, cancelled: true).provablyUnsent)
        // Metrics decide when present.
        XCTAssertTrue(TransportFailure(code: .timedOut, sent: false).provablyUnsent, "LAN connect timeout")
        XCTAssertFalse(TransportFailure(code: .networkConnectionLost, sent: true).provablyUnsent)
        XCTAssertEqual(Transport.classify(TransportFailure(code: .secureConnectionFailed, sent: true)), .reset,
                       "an SSL error after the request left is ambiguous")
        // decide() treats tls like any non-offline transport failure (as the Kotlin engine does).
        let tls = ServerOutcome(transport: .tls)
        XCTAssertEqual(Decide.decide(Given(flow: .backup, itemState: .hashed, lastAction: .check), tls),
                       Decision(nextState: .hashed, action: .backoffRetry, attemptsDelta: 1))
        XCTAssertEqual(Decide.decide(Given(flow: .auth, itemState: nil, lastAction: .refresh), tls).action, .backoffRetry)
    }

    func testAccessTokenRefreshedProactively() async throws {
        let refreshes = Counter()
        StubServer.shared.install { _ in .json(200, tokensJSON(refreshes.next())) }
        let clock = ManualClock()
        let auth = AuthManager(store: InMemoryCredentialStore(testCredentials([base])), http: stubHTTP(),
                               endpoints: Endpoints([base]), uptime: { clock.now })
        let first = try await auth.accessToken()
        XCTAssertEqual(first, "pt_at_1")
        clock.advance(13 * 60)
        let second = try await auth.accessToken()
        XCTAssertEqual(second, "pt_at_1", "still fresh")
        XCTAssertEqual(refreshes.value, 1)
        clock.advance(60)
        let third = try await auth.accessToken()
        XCTAssertEqual(third, "pt_at_2", "14 min after issue it is refreshed before use")
        XCTAssertEqual(refreshes.value, 2)
    }

    func testCredentialReadErrorIsTransientNotRepair() async throws {
        StubServer.shared.install { _ in .json(200, tokensJSON(1)) }
        let store = UnreadableStore()
        let repairs = Counter()
        let auth = AuthManager(store: store, http: stubHTTP(), endpoints: Endpoints([base]),
                               onNeedsRepair: { repairs.next() })
        let out = await auth.onUnauthorized()
        XCTAssertEqual(out, .transient(ServerOutcome(transport: .reset)))
        XCTAssertEqual(store.wipes, 0)
        XCTAssertEqual(repairs.value, 0)
        XCTAssertTrue(StubServer.shared.requests.isEmpty)

        let missing = AuthManager(store: InMemoryCredentialStore(nil), http: stubHTTP(), endpoints: Endpoints([base]))
        let none = await missing.onUnauthorized()
        XCTAssertEqual(none, .needsRepair(nil), "nothing stored means pair again")
    }

    func testRefreshTokenReused401IsNotRefreshed() async throws {
        let s = stack { _ in .problem(401, "refresh_token_reused") }
        let out = await s.api.check([CheckItem(sha256: "x", sizeBytes: 1)])
        guard case let .fail(raw, _) = out else { return XCTFail("expected fail") }
        XCTAssertEqual(raw.problem?.code, "refresh_token_reused")
        XCTAssertEqual(s.refreshes.value, 1, "only the initial token; refreshing cannot help")
    }

    func testForeignHostNeverGetsTheToken() async throws {
        let s = stack { _ in .empty(204) }
        let out = await s.api.perform(TusRequests.terminate(URL(string: "https://evil.example/api/v1/uploads/x")!))
        guard case let .fail(_, failure) = out else { return XCTFail("expected fail") }
        XCTAssertEqual(failure, .foreignHost("evil.example"))
        XCTAssertFalse(StubServer.shared.requests.contains { $0.url.host == "evil.example" })
    }

    func testLenientServerInfoAndProblem() throws {
        let info = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"server_id":"s","upload":{"tus_version":7}}"#.utf8))
        XCTAssertEqual(info.serverId, "s")
        XCTAssertNil(info.name)
        XCTAssertNil(info.upload.maxFileBytes)
        XCTAssertEqual(info.upload.recommendedChunkBytes, 8_388_608)
        XCTAssertEqual(info.upload.tusVersion, "1.0.0")
        XCTAssertEqual(info.capabilities, [])
        let bare = try JSONDecoder().decode(ServerInfo.self, from: Data(#"{"server_id":"s"}"#.utf8))
        XCTAssertEqual(bare.upload.recommendedChunkBytes, 8_388_608)

        XCTAssertEqual(Problem(.object(["title": .string("Bad Gateway")]))?.title, "Bad Gateway")
        XCTAssertNil(Problem(.object(["detail": .string("x")])))
    }

    // MARK: - client

    func testClientHeader() async throws {
        let checks = Counter()
        let s = stack { [checkBody, serverInfoBody] r in
            switch (r.method, r.path) {
            case (_, "/api/v1/server/info"): return .json(200, serverInfoBody)
            case (_, "/api/v1/sync/check"):
                return checks.next() == 1 ? .problem(401, "token_expired") : .json(200, checkBody)
            case ("HEAD", _): return .empty(200, ["Upload-Offset": "0"])
            default: return .empty(204)
            }
        }
        let info = try await s.api.serverInfo()
        XCTAssertEqual(info.upload.recommendedChunkBytes, 8_388_608)
        XCTAssertEqual(info.upload.maxFileBytes, 53_687_091_200)
        XCTAssertEqual(info.minClientVersion["ios"], "0.1.0")
        XCTAssertEqual(info.serverId, "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f")

        let check = await s.api.check([CheckItem(sha256: "fbbab289", sizeBytes: 3, localId: "a-1")], confirmOnDisk: true)
        guard case let .ok(results, _) = check else { return XCTFail("expected ok, got \(check)") }
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(s.refreshes.value, 2, "initial token, then one refresh after the 401")

        // Foreground tus calls go through the same client.
        let head = await s.api.perform(TusRequests.head(URL(string: "\(base)/api/v1/uploads/u9")!))
        guard case let .ok(_, headRaw) = head else { return XCTFail("expected ok, got \(head)") }
        XCTAssertEqual(headRaw.uploadOffset, 0)
        _ = await s.api.perform(TusRequests.terminate(URL(string: "/api/v1/uploads/u9", relativeTo: URL(string: base))!.absoluteURL))

        let reqs = StubServer.shared.requests
        XCTAssertEqual(reqs.map(\.method), ["GET", "POST", "POST", "POST", "POST", "HEAD", "DELETE"])
        for r in reqs { XCTAssertEqual(r.header("PicTunnel-Client"), clientHeaderValue, "\(r.method) \(r.path)") }
        XCTAssertNil(reqs[0].header("Authorization"), "server info is public")
        let checkReq = try XCTUnwrap(reqs.last { $0.path == "/api/v1/sync/check" })
        XCTAssertEqual(checkReq.header("Authorization"), "Bearer pt_at_2")
        XCTAssertEqual(checkReq.header("Content-Type"), "application/json")
        let item = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: checkReq.body)["items"]?.arrayValue?.first)
        XCTAssertEqual(item["local_id"], .string("a-1"))
        XCTAssertEqual(item["size_bytes"]?.intValue, 3)
        XCTAssertEqual(item["confirm_on_disk"], .bool(true))
        XCTAssertEqual(reqs[5].header("Authorization"), "Bearer pt_at_2")
        XCTAssertEqual(reqs[5].header("Tus-Resumable"), "1.0.0")
    }

    func testEngineSessionCarriesClientHeader() {
        let session = EngineHTTP.makeSession(pinning: PinningDelegate(pin: { "pin" }), clientHeader: clientHeaderValue)
        XCTAssertEqual(session.configuration.httpAdditionalHeaders?["PicTunnel-Client"] as? String, clientHeaderValue)
        XCTAssertTrue(session.delegate is PinningDelegate)
        XCTAssertEqual(EngineHTTP.clientHeader(version: "1.2.3"), "ios/1.2.3")
    }

    func testCheckParsesAllVerdicts() async throws {
        let s = stack { [checkBody] _ in .json(200, checkBody) }
        let out = await s.api.check([CheckItem(sha256: "x", sizeBytes: 1)])
        guard case let .ok(results, raw) = out else { return XCTFail("expected ok") }
        XCTAssertEqual(results.map(\.verdict), ["exists", "missing", "partial", "tombstoned", "brand_new_verdict"])
        XCTAssertEqual(results[0].assetId, "01928f40-0000-7000-8000-000000000001")
        XCTAssertEqual(results[0].assetState, "active")
        XCTAssertEqual(results[0].hasLiveVideo, false)
        XCTAssertEqual(results[0].onDisk, true)
        XCTAssertEqual(results[2].upload, CheckUpload(id: "u1", url: "/api/v1/uploads/u1", offset: 1_048_576,
                                                      length: 3_145_728, expiresAt: "2026-10-04T12:00:00Z"))
        XCTAssertEqual(results[3].deletedAt, "2026-10-01T00:00:00Z")
        XCTAssertNil(results[1].assetId)
        // The raw outcome keeps the body for decide().
        XCTAssertEqual(raw.status, 200)
        XCTAssertEqual(raw.body?["results"]?.arrayValue?.count, 5)
        // Per-item outcomes feed decide() one result at a time.
        XCTAssertEqual(Decide.decide(Given(flow: .backup, itemState: .hashed, lastAction: .check),
                                     results[2].outcome(from: raw)).action, .resumeUpload)
        XCTAssertEqual(Decide.decide(Given(flow: .backup, itemState: .hashed, lastAction: .check),
                                     results[4].outcome(from: raw)).action, .skipThisRun)
    }

    func testCheckBatchesAtMost1000() async throws {
        let s = stack { r in
            let n = (try? JSONDecoder().decode(JSONValue.self, from: r.body))?["items"]?.arrayValue?.count ?? 0
            let one = #"{"sha256":"x","verdict":"missing"}"#
            return .json(200, #"{"results":["# + Array(repeating: one, count: n).joined(separator: ",") + "]}")
        }
        let items = (0..<2500).map { CheckItem(sha256: String($0), sizeBytes: 1) }
        guard case let .ok(results, _) = await s.api.check(items) else { return XCTFail("expected ok") }
        XCTAssertEqual(results.count, 2500)
        let sizes = StubServer.shared.requests.filter { $0.path == "/api/v1/sync/check" }.map {
            (try? JSONDecoder().decode(JSONValue.self, from: $0.body))?["items"]?.arrayValue?.count ?? 0
        }
        XCTAssertEqual(sizes, [1000, 1000, 500])
    }

    func testRetryAfterParsed() async throws {
        let s = stack { _ in .problem(429, "rate_limited", headers: ["Retry-After": "120"]) }
        let out = await s.api.check([CheckItem(sha256: "x", sizeBytes: 1)])
        guard case let .fail(raw, failure) = out else { return XCTFail("expected fail") }
        XCTAssertNil(failure)
        XCTAssertEqual(raw.status, 429)
        XCTAssertEqual(raw.retryAfter(now: Date()), 120)
        let p = try XCTUnwrap(raw.problem)
        XCTAssertEqual(p.code, "rate_limited")
        XCTAssertEqual(p.type, "urn:pictunnel:problem:rate_limited")
        XCTAssertEqual(p.status, 429)
        XCTAssertEqual(p.detail, "d")
        XCTAssertEqual(Decide.decide(Given(flow: .backup, itemState: .hashed, lastAction: .check), raw).action,
                       .waitRetryAfter)

        let now = ISO8601DateFormatter().date(from: "2026-10-04T11:59:00Z")!
        func ra(_ v: String) -> TimeInterval? { ServerOutcome(status: 503, headers: ["retry-after": v]).retryAfter(now: now) }
        XCTAssertEqual(ra("Sun, 04 Oct 2026 12:00:00 GMT"), 60)
        XCTAssertEqual(ra("Sun, 04 Oct 2026 11:00:00 GMT"), 0)
        XCTAssertEqual(ra("0"), 0)
        XCTAssertNil(ra("soon"))
        XCTAssertNil(ra("-5"))
        XCTAssertNil(ServerOutcome(status: 503).retryAfter(now: now))
    }

    func testServerInfoFailureThrows() async throws {
        let s = stack { _ in .problem(503, "server_unavailable") }
        do {
            _ = try await s.api.serverInfo()
            XCTFail("expected ServerError")
        } catch let e as ServerError {
            XCTAssertEqual(e.raw.status, 503)
            XCTAssertEqual(e.raw.problem?.code, "server_unavailable")
        }
    }

    func testNonJsonErrorBodyIsTolerated() async throws {
        let s = stack { _ in .http(502, ["Content-Type": "text/html"], Data("<html>bad gateway</html>".utf8)) }
        let out = await s.api.check([CheckItem(sha256: "x", sizeBytes: 1)])
        guard case let .fail(raw, _) = out else { return XCTFail("expected fail") }
        XCTAssertEqual(raw.status, 502)
        XCTAssertNil(raw.body)
        XCTAssertNil(raw.problem)
    }

    func testTransportFailureIsAnOutcome() async throws {
        let s = stack { r in r.path == "/api/v1/sync/check" ? .error(.networkConnectionLost) : .empty(500) }
        let out = await s.api.check([CheckItem(sha256: "x", sizeBytes: 1)])
        guard case let .fail(raw, _) = out else { return XCTFail("expected fail") }
        XCTAssertEqual(raw.transport, .reset)
        XCTAssertNil(raw.status)
    }

    func testInMemoryCredentialStore() throws {
        let store = InMemoryCredentialStore(nil)
        XCTAssertNil(try store.load())
        try store.save(testCredentials())
        XCTAssertEqual(try store.load(), testCredentials())
        try store.wipe()
        XCTAssertNil(try store.load())
        XCTAssertEqual(store.wipes, 1)
        XCTAssertEqual(store.saved.count, 1)
    }

    // MARK: - pinning (pure parts, every platform)

    func testSpkiHashMatchesOpenSSL() throws {
        // Fixtures were generated with openssl; *.spki holds base64url(SHA-256(SubjectPublicKeyInfo DER)).
        for name in ["leaf", "ca", "other"] {
            let spki = try Pinning.spkiSHA256(fromDERCertificate: try fixture("pinning/\(name).der"))
            XCTAssertEqual(spki, try fixtureText("pinning/\(name).spki"), name)
            XCTAssertEqual(spki.count, 43, "unpadded base64url, the pairing `fp` format")
        }
        XCTAssertThrowsError(try Pinning.spkiSHA256(fromDERCertificate: Data([0x30, 0x03, 0x02, 0x01])))
        XCTAssertThrowsError(try Pinning.spkiSHA256(fromDERCertificate: Data()))
        let der = try fixture("pinning/leaf.der")
        XCTAssertThrowsError(try Pinning.spkiSHA256(fromDERCertificate: der.prefix(200)), "truncated")
    }

    func testPinRule() throws {
        let leaf = try fixture("pinning/leaf.der")
        let pin = try fixtureText("pinning/leaf.spki")
        let other = try fixtureText("pinning/other.spki")
        // A chain the system trusts for the host is accepted whatever the pin.
        XCTAssertTrue(Pinning.accept(systemTrusted: true, leafDER: leaf, pin: other))
        XCTAssertTrue(Pinning.accept(systemTrusted: true, leafDER: nil, pin: nil))
        // Otherwise the leaf's SPKI must equal the stored pin.
        XCTAssertTrue(Pinning.accept(systemTrusted: false, leafDER: leaf, pin: pin))
        XCTAssertTrue(Pinning.accept(systemTrusted: false, leafDER: leaf, pin: pin + "="), "padding is ignored")
        XCTAssertFalse(Pinning.accept(systemTrusted: false, leafDER: leaf, pin: other))
        XCTAssertFalse(Pinning.accept(systemTrusted: false, leafDER: leaf, pin: nil))
        XCTAssertFalse(Pinning.accept(systemTrusted: false, leafDER: leaf, pin: ""))
        XCTAssertFalse(Pinning.accept(systemTrusted: false, leafDER: nil, pin: pin))
        XCTAssertFalse(Pinning.accept(systemTrusted: false, leafDER: Data([1, 2, 3]), pin: pin))
    }

    // MARK: - pinning with SecTrust (Apple platforms)

    #if canImport(Security)
    private func trust(_ names: [String]) throws -> SecTrust {
        let certs = try names.map { try XCTUnwrap(SecCertificateCreateWithData(nil, try fixture("pinning/\($0).der") as CFData)) }
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certs as CFArray, SecPolicyCreateBasicX509(), &trust), errSecSuccess)
        let t = try XCTUnwrap(trust)
        // The fixture leaf is valid from 2026-10-17 for 800 days; evaluate at a fixed date inside that window.
        SecTrustSetVerifyDate(t, ISO8601DateFormatter().date(from: "2027-06-01T00:00:00Z")! as CFDate)
        SecTrustSetNetworkFetchAllowed(t, false)
        return t
    }

    func testRejectsChangedPin() throws {
        let pin = try fixtureText("pinning/leaf.spki")
        let other = try fixtureText("pinning/other.spki")

        // Not trusted by the system (the test root is not an anchor): the pin decides.
        XCTAssertTrue(Pinning.evaluate(try trust(["leaf", "ca"]), host: "192.168.1.10", pin: pin))
        XCTAssertFalse(Pinning.evaluate(try trust(["leaf", "ca"]), host: "192.168.1.10", pin: other),
                       "a changed certificate is rejected")
        XCTAssertFalse(Pinning.evaluate(try trust(["other"]), host: "pictunnel.test", pin: pin),
                       "a different server key is rejected")
        XCTAssertFalse(Pinning.evaluate(try trust(["leaf", "ca"]), host: "192.168.1.10", pin: nil))

        // Trusted by the system and matching the host: accepted without the pin.
        let anchored = try trust(["leaf", "ca"])
        let root = try XCTUnwrap(SecCertificateCreateWithData(nil, try fixture("pinning/ca.der") as CFData))
        SecTrustSetAnchorCertificates(anchored, [root] as CFArray)
        SecTrustSetAnchorCertificatesOnly(anchored, true)
        XCTAssertTrue(Pinning.evaluate(anchored, host: "pictunnel.test", pin: other))
        // A trusted chain for another host is not enough on its own.
        XCTAssertFalse(Pinning.evaluate(anchored, host: "evil.test", pin: other))
    }
    #endif
}

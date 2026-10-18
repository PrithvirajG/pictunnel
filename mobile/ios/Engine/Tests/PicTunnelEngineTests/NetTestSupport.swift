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

let clientHeaderValue = "ios/0.1.0"

/// One request as the stub saw it, with its body read out of `httpBody` or `httpBodyStream`.
struct Recorded: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data
    let timeout: TimeInterval

    var path: String { url.path }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// A canned reply: an HTTP response, or a transport error.
enum StubReply: Sendable {
    case http(Int, [String: String], Data)
    case error(URLError.Code)

    static func json(_ status: Int, _ body: String, contentType: String = "application/json",
                     headers: [String: String] = [:]) -> StubReply {
        var h = headers
        h["Content-Type"] = contentType
        return .http(status, h, Data(body.utf8))
    }

    static func problem(_ status: Int, _ code: String, headers: [String: String] = [:]) -> StubReply {
        json(status,
             #"{"type":"urn:pictunnel:problem:\#(code)","title":"\#(code)","status":\#(status),"detail":"d","code":"\#(code)"}"#,
             contentType: "application/problem+json", headers: headers)
    }

    static func empty(_ status: Int, _ headers: [String: String] = [:]) -> StubReply {
        .http(status, headers, Data())
    }
}

/// A `URLProtocol` that answers every request of a session built by `StubServer.session()` from
/// the installed handler. Works with FoundationNetworking on Linux and Foundation on Apple platforms.
final class StubProtocol: URLProtocol {
    /// Loopback requests go to the real network stack (see `SilentListener`).
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host != "127.0.0.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        let rec = Recorded(
            method: req.httpMethod ?? "GET",
            url: req.url!,
            headers: req.allHTTPHeaderFields ?? [:],
            body: Self.body(of: req),
            timeout: req.timeoutInterval
        )
        // Answer off the loading thread so a slow handler never blocks other requests.
        nonisolated(unsafe) let proto = self
        DispatchQueue.global().async {
            let reply = StubServer.shared.handle(rec)
            if proto.stopped { return } // cancelled meanwhile: answer nothing
            let client = proto.client
            switch reply {
            case let .error(code):
                client?.urlProtocol(proto, didFailWithError: URLError(code))
            case let .http(status, headers, data):
                let resp = HTTPURLResponse(url: rec.url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
                client?.urlProtocol(proto, didReceive: resp, cacheStoragePolicy: .notAllowed)
                if !data.isEmpty { client?.urlProtocol(proto, didLoad: data) }
                client?.urlProtocolDidFinishLoading(proto)
            }
        }
    }

    private let stopLock = NSLock()
    private var _stopped = false
    var stopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return _stopped
    }

    override func stopLoading() {
        stopLock.lock()
        _stopped = true
        stopLock.unlock()
    }

    private static func body(of req: URLRequest) -> Data {
        if let b = req.httpBody { return b }
        guard let stream = req.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

/// The process-wide stub "server": a handler plus the log of requests it answered.
final class StubServer: @unchecked Sendable {
    static let shared = StubServer()

    private let lock = NSLock()
    private var handler: @Sendable (Recorded) -> StubReply = { _ in .empty(500) }
    private var log: [Recorded] = []

    func install(_ h: @escaping @Sendable (Recorded) -> StubReply) {
        lock.lock(); defer { lock.unlock() }
        handler = h
        log = []
    }

    func handle(_ r: Recorded) -> StubReply {
        lock.lock()
        log.append(r)
        let h = handler
        lock.unlock()
        return h(r)
    }

    var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

/// A thread-safe counter for handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    @discardableResult func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return n
    }
}

func tokensJSON(_ n: Int) -> String {
    #"{"access_token":"pt_at_\#(n)","access_token_expires_at":"2026-10-03T12:30:00Z","refresh_token":"pt_rt_\#(n)","refresh_token_expires_at":"2027-01-01T12:15:00Z"}"#
}

func testCredentials(_ endpoints: [String] = ["https://pictunnel.test"]) -> Credentials {
    Credentials(serverId: "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f", endpoints: endpoints, pinSpki: "",
                refreshToken: "pt_rt_0", deviceId: "01928f3f-1111-7000-8000-0000000d0001")
}

/// Engine/Tests/Fixtures, next to the test target.
let fixturesDir: URL = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent() // PicTunnelEngineTests
    url.deleteLastPathComponent() // Tests
    return url.appendingPathComponent("Fixtures")
}()

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixturesDir.appendingPathComponent(name))
}

func fixtureText(_ name: String) throws -> String {
    String(decoding: try fixture(name), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Counter-pattern content (P§10.1): byte i is (i + seed) mod 256.
func counterBytes(length: Int, seed: Int = 0, start: Int = 0) -> Data {
    Data((start..<(start + length)).map { UInt8(truncatingIfNeeded: $0 + seed) })
}

func sha256Hex(_ data: Data) -> String {
    var h = SHA256Stream()
    h.update(data)
    return h.finalizeHex()
}

/// Engine HTTP over the stub. Stubbed tasks carry no real connection metrics, so metrics are off
/// and the error-code rule decides what was sent.
func stubHTTP() -> EngineHTTP {
    EngineHTTP(session: StubServer.session(), clientHeader: clientHeaderValue, useTaskMetrics: false)
}

/// A loopback TCP port that accepts connections into its backlog but never answers: an endpoint
/// that never responds.
final class SilentListener {
    let port: UInt16
    private let fd: Int32

    init() throws {
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard s >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, len) }
        }
        guard bound == 0, listen(s, 16) == 0 else {
            close(s)
            throw POSIXError(.EADDRINUSE)
        }
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        guard named == 0 else {
            close(s)
            throw POSIXError(.EIO)
        }
        fd = s
        port = UInt16(bigEndian: addr.sin_port)
    }

    deinit { close(fd) }
}

/// A settable monotonic clock.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return t
    }
    func advance(_ by: TimeInterval) {
        lock.lock()
        t += by
        lock.unlock()
    }
}

/// A store whose reads fail (e.g. Keychain locked before first unlock).
final class UnreadableStore: CredentialStore, @unchecked Sendable {
    struct Locked: Error {}
    var wipes = 0
    func load() throws -> Credentials? { throw Locked() }
    func save(_ c: Credentials) throws {}
    func wipe() throws { wipes += 1 }
}

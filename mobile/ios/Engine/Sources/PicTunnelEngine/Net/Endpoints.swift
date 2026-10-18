import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum EndpointsError: Error, Sendable {
    case noEndpoints
    /// Every endpoint failed before anything was sent. `tlsRejectedHost` names an endpoint whose
    /// TLS handshake failed or whose certificate the pinning rule refused.
    case allFailed(last: Error, tlsRejectedHost: String?)
}

/// The server's endpoints in stored order, LAN first (R9, M§4.4).
///
/// A request goes to the active endpoint first, then to the others in stored order, falling back
/// on any failure where the request provably never reached the server (`TransportFailure
/// .provablyUnsent`: task metrics show no request start, the pin was rejected, or without metrics
/// an error that can only happen before sending). Once a request may have reached the server its
/// failure is returned as is, so an ambiguous upload is resolved by HEAD or check (R2) and never
/// re-sent elsewhere. A cancelled request is never replayed.
///
/// LAN connect is bounded to 3 s: URLSession has no separate connect timeout, so before a LAN
/// endpoint is used for the first time since it last answered, a `GET /healthz` with a 3 s timeout
/// checks it is reachable (this also runs the TLS handshake and pinning before any body is sent).
/// The real request then keeps its normal timeout. Any failure on a LAN endpoint forgets it, so the
/// next request probes again.
public final class Endpoints: @unchecked Sendable {
    public static let lanConnectTimeout: TimeInterval = 3
    public static let probePath = "/healthz"

    public let urls: [URL]
    private let lock = NSLock()
    private var activeIndex = 0
    /// Endpoints that answered since they last failed or the network changed.
    private var reached = Set<Int>()

    public init(_ endpoints: [String]) {
        urls = endpoints.compactMap { s in
            var t = s.trimmingCharacters(in: .whitespaces)
            while t.hasSuffix("/") { t.removeLast() }
            guard let u = URL(string: t), u.scheme != nil, u.host != nil else { return nil }
            return u
        }
    }

    /// The endpoint requests go to first.
    public var active: URL {
        lock.lock()
        defer { lock.unlock() }
        return urls.isEmpty ? URL(fileURLWithPath: "/") : urls[activeIndex]
    }

    /// Back to stored order, e.g. after a network change: the LAN gets another chance.
    public func resetToPreferred() {
        lock.lock()
        defer { lock.unlock() }
        activeIndex = 0
        reached.removeAll()
    }

    /// Resolves a server-relative `Location` (or an absolute URL) against the active endpoint.
    public func resolve(_ location: String) -> URL? {
        URL(string: location, relativeTo: active)?.absoluteURL
    }

    /// The percent-encoded path and query of `target` when it is relative or points at one of our
    /// endpoints, so it can be replayed on whichever endpoint is active; nil for a foreign host,
    /// which never gets the bearer token.
    public func relativize(_ target: String) -> String? {
        if target.hasPrefix("/") { return target }
        guard let c = URLComponents(string: target), let host = c.host else { return nil }
        let match = urls.contains { e in
            e.scheme?.lowercased() == c.scheme?.lowercased() && e.host?.lowercased() == host.lowercased()
                && Self.port(e) == Self.port(scheme: c.scheme, port: c.port)
        }
        guard match else { return nil }
        let path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        return c.percentEncodedQuery.map { "\(path)?\($0)" } ?? path
    }

    /// Sends `build(endpoint + path)` to the active endpoint, falling back through the others.
    /// The endpoint that answers becomes active. Any HTTP status counts as an answer.
    public func execute(_ http: EngineHTTP, path: String,
                        _ build: (URL) -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (order, alreadyReached) = snapshot()
        guard !order.isEmpty else { throw EndpointsError.noEndpoints }

        var last: Error = TransportFailure(code: .cannotConnectToHost, sent: false)
        var tlsHost: String?
        func note(_ error: Error, host: String) {
            last = error
            if let f = error as? TransportFailure, f.isTLS { tlsHost = tlsHost ?? f.pinRejectedHost ?? host }
        }

        for i in order {
            try Task.checkCancellation()
            let base = urls[i]
            let host = base.host ?? ""
            let lan = Self.isLan(host)
            if lan, !alreadyReached.contains(i) {
                guard let probeURL = Self.join(base, Self.probePath) else { continue }
                var probe = URLRequest(url: probeURL)
                probe.timeoutInterval = Self.lanConnectTimeout
                do {
                    _ = try await http.send(probe)
                    markReached(i)
                } catch {
                    if Self.isCancellation(error) { throw error }
                    note(error, host: host)
                    continue
                }
            }
            guard let url = Self.join(base, path) else { throw TransportFailure(code: .badURL, sent: false) }
            do {
                let result = try await http.send(build(url))
                markReached(i, active: true)
                return result
            } catch {
                forget(i)
                if Self.isCancellation(error) { throw error }
                guard let f = error as? TransportFailure, f.provablyUnsent else { throw error }
                note(error, host: host)
            }
        }
        throw EndpointsError.allFailed(last: last, tlsRejectedHost: tlsHost)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        return (error as? TransportFailure)?.cancelled == true
    }

    // MARK: - classification

    /// Private, link-local, loopback and mDNS/single-label hosts (RFC 1918, RFC 4193, RFC 3927).
    public static func isLan(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        if host.contains(":") { return isLanIPv6(host) }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        if parts.count == 4, octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        return host.hasSuffix(".local") || !host.contains(".")
    }

    private static func isLanIPv6(_ host: String) -> Bool {
        let addr = host.split(separator: "%").first.map(String.init) ?? host
        if addr == "::1" { return true }
        guard let first = addr.split(separator: ":", omittingEmptySubsequences: false).first,
              !first.isEmpty, let v = UInt16(first, radix: 16) else { return false }
        return (v & 0xFE00) == 0xFC00 /* fc00::/7 */ || (v & 0xFFC0) == 0xFE80 /* fe80::/10 */
    }

    // MARK: - state

    private func snapshot() -> ([Int], Set<Int>) {
        lock.lock()
        defer { lock.unlock() }
        guard !urls.isEmpty else { return ([], []) }
        let start = min(activeIndex, urls.count - 1)
        return ([start] + urls.indices.filter { $0 != start }, reached)
    }

    private func markReached(_ i: Int, active: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        reached.insert(i)
        if active { activeIndex = i }
    }

    private func forget(_ i: Int) {
        lock.lock()
        defer { lock.unlock() }
        reached.remove(i)
    }

    static func join(_ base: URL, _ path: String) -> URL? {
        URL(string: base.absoluteString + (path.hasPrefix("/") ? path : "/" + path))
    }

    private static func port(_ u: URL) -> Int? {
        port(scheme: u.scheme, port: u.port)
    }

    private static func port(scheme: String?, port: Int?) -> Int? {
        if let port { return port }
        switch scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

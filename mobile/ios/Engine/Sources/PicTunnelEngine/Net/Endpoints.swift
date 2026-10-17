import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum EndpointsError: Error, Sendable {
    case noEndpoints
    /// Every endpoint failed. `onlyUnreachable` is true when none of them was reached at all
    /// (so the device is effectively offline); `tlsRejectedHost` names an endpoint that refused
    /// TLS under the pinning rule.
    case allFailed(last: Error, onlyUnreachable: Bool, tlsRejectedHost: String?)
}

/// The server's endpoints in stored order, LAN first (R9, M§4.4).
///
/// A request goes to the active endpoint first, then to the others in stored order. Before a LAN
/// endpoint is used for the first time since the last network change, a `GET /healthz` with a 3 s
/// timeout checks that it is reachable; this is the iOS stand-in for OkHttp's connect timeout
/// (URLSession has no separate connect timeout) and keeps the real request on the normal timeout.
/// The probe also completes the TLS handshake, so pinning runs before any request body is sent.
///
/// Falling back to the next endpoint happens only when the request surely never reached the
/// server (no route, DNS, refused, TLS rejected). A timeout or a dropped connection on a reached
/// endpoint is ambiguous (R2) and is returned to the caller instead of being replayed elsewhere.
public final class Endpoints: @unchecked Sendable {
    public static let lanConnectTimeout: TimeInterval = 3
    public static let probePath = "/healthz"

    public let urls: [URL]
    private let lock = NSLock()
    private var activeIndex = 0
    /// Endpoints that answered since the last network change.
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
        return urls.isEmpty ? URL(string: "https://invalid.invalid")! : urls[activeIndex]
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

    /// The path and query of `target` when it is relative or points at one of our endpoints, so it
    /// can be replayed on whichever endpoint is active; nil for a foreign host.
    public func relativize(_ target: String) -> String? {
        if target.hasPrefix("/") { return target }
        guard let u = URL(string: target), let host = u.host else { return nil }
        let match = urls.contains { e in
            e.scheme?.lowercased() == u.scheme?.lowercased() && e.host?.lowercased() == host.lowercased()
                && Self.port(e) == Self.port(u)
        }
        guard match else { return nil }
        let path = u.path.isEmpty ? "/" : u.path
        return u.query.map { "\(path)?\($0)" } ?? path
    }

    /// Sends `build(endpoint + path)` to the active endpoint, falling back through the others.
    /// The endpoint that answers becomes active. Any HTTP status counts as an answer.
    public func execute(_ http: EngineHTTP, path: String,
                        _ build: (URL) -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (order, alreadyReached) = snapshot()
        guard !order.isEmpty else { throw EndpointsError.noEndpoints }

        var last: Error = URLError(.cannotConnectToHost)
        var onlyUnreachable = true
        var tlsHost: String?
        func note(_ error: Error, host: String, unreachable: Bool) {
            last = error
            if !unreachable { onlyUnreachable = false }
            if Self.isTLSRejection(error) {
                tlsHost = tlsHost ?? host
                onlyUnreachable = false
            }
        }

        for i in order {
            let base = urls[i]
            let host = base.host ?? ""
            if !alreadyReached.contains(i), Self.isLan(host) {
                var probe = URLRequest(url: Self.join(base, Self.probePath))
                probe.timeoutInterval = Self.lanConnectTimeout
                do {
                    _ = try await http.send(probe)
                    markReached(i)
                } catch {
                    note(error, host: host, unreachable: true)
                    continue
                }
            }
            do {
                let result = try await http.send(build(Self.join(base, path)))
                markReached(i, active: true)
                return result
            } catch {
                guard Self.isUnsent(error) else { throw error }
                forget(i)
                note(error, host: host, unreachable: true)
            }
        }
        throw EndpointsError.allFailed(last: last, onlyUnreachable: onlyUnreachable, tlsRejectedHost: tlsHost)
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

    /// Errors raised before the request could have reached the server.
    static func isUnsent(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .callIsActive,
             .appTransportSecurityRequiresSecureConnection:
            return true
        default:
            return isTLSRejection(error)
        }
    }

    /// The handshake failed or the pinning delegate refused the certificate (which URLSession
    /// reports as `cancelled`).
    static func isTLSRejection(_ error: Error) -> Bool {
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .cancelled, .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
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

    static func join(_ base: URL, _ path: String) -> URL {
        URL(string: base.absoluteString + (path.hasPrefix("/") ? path : "/" + path))!
    }

    private static func port(_ u: URL) -> Int? {
        if let p = u.port { return p }
        switch u.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

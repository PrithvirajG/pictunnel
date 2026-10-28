#if os(iOS)
import Foundation
import Network

/// mDNS discovery of `_pictunnel._tcp` for manual setup (M§4.4, P§6.4) with `NWBrowser`. Needs the
/// `NSLocalNetworkUsageDescription` and `NSBonjourServices` Info.plist keys. Each service found is
/// resolved to an address by opening (and at once closing) a TCP connection to it.
public enum BonjourDiscovery {
    public static let serviceType = "_pictunnel._tcp"

    /// The https URLs of the servers found within `timeoutMs`.
    public static func discover(timeoutMs: Int) async -> [String] {
        let queue = DispatchQueue(label: "io.github.prithvirajg.pictunnel.bonjour")
        let found = Resolver(queue: queue)
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for r in results { found.resolve(r.endpoint) }
        }
        browser.start(queue: queue)
        try? await Task.sleep(nanoseconds: UInt64(max(timeoutMs, 100)) * 1_000_000)
        browser.cancel()
        return found.finish()
    }

    /// `https://host:port`, IPv6 bracketed and without its interface scope.
    static func url(_ host: NWEndpoint.Host, _ port: NWEndpoint.Port) -> String? {
        let h: String
        switch host {
        case let .ipv4(a):
            h = "\(a)"
        case let .ipv6(a):
            let s = "\(a)"
            h = "[\(s.split(separator: "%").first.map(String.init) ?? s)]"
        case let .name(n, _):
            h = n
        @unknown default:
            return nil
        }
        return "https://\(h):\(port.rawValue)"
    }
}

private final class Resolver: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var seen = Set<String>()
    private var urls: [String] = []
    private var connections: [NWConnection] = []

    init(queue: DispatchQueue) { self.queue = queue }

    func resolve(_ endpoint: NWEndpoint) {
        let key = "\(endpoint)"
        lock.lock()
        guard seen.insert(key).inserted else {
            lock.unlock()
            return
        }
        let conn = NWConnection(to: endpoint, using: .tcp)
        connections.append(conn)
        lock.unlock()
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = conn?.currentPath?.remoteEndpoint,
                   let url = BonjourDiscovery.url(host, port) {
                    self?.add(url)
                }
                conn?.cancel()
            case .failed, .waiting:
                conn?.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    private func add(_ url: String) {
        lock.lock()
        if !urls.contains(url) { urls.append(url) }
        lock.unlock()
    }

    func finish() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        connections.forEach { $0.cancel() }
        connections = []
        return urls
    }
}
#endif

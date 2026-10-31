#if os(iOS)
import Foundation
import Network
import PicTunnelEngine
import UIKit

/// The "Wi-Fi only" and "charging only" conditions of a run (M§4.6), and network change events
/// (R9: back to the LAN endpoint first). Wi-Fi only means a non-expensive Wi-Fi or wired path;
/// charging means plugged in (charging or full).
public final class RunConditions: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.github.prithvirajg.pictunnel.path")
    private let lock = NSLock()
    private var path: NWPath?
    private var lastSignature: String?
    private var pluggedIn = true
    private var _onNetworkChange: (() -> Void)?
    private var pathWaiters: [OnceResume] = []
    private var observer: NSObjectProtocol?

    public init() {}

    /// Called on a network change, and once on the first path report (a run that waited for the
    /// network state can start then).
    public var onNetworkChange: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onNetworkChange }
        set { lock.lock(); _onNetworkChange = newValue; lock.unlock() }
    }

    /// Starts monitoring (battery state is read on the main actor).
    @MainActor
    public func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBattery()
        observer = NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateBattery() }
        }
        monitor.pathUpdateHandler = { [weak self] p in self?.update(p) }
        monitor.start(queue: queue)
    }

    /// Why a run must wait under `settings`, or nil when it may start. With "Wi-Fi only" a run
    /// also waits while the network state is not known yet (before the first path report).
    public func blocker(_ settings: EngineSettings) -> PauseReason? {
        lock.lock()
        let p = path
        let plugged = pluggedIn
        lock.unlock()
        if settings.wifiOnly, !Self.unmetered(p) { return .wifiRequired }
        if settings.chargingOnly, !plugged { return .chargingRequired }
        return nil
    }

    /// True on a satisfied, non-expensive Wi-Fi or wired path.
    public var onUnmeteredNetwork: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.unmetered(path)
    }

    /// Waits until the first path report, at most `timeoutMs` (a background launch asks before
    /// the monitor has reported).
    public func waitForFirstPath(timeoutMs: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OnceResume(cont)
            lock.lock()
            if path != nil {
                lock.unlock()
                once.resume()
                return
            }
            pathWaiters.append(once)
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(max(timeoutMs, 0))) { once.resume() }
        }
    }

    private static func unmetered(_ p: NWPath?) -> Bool {
        guard let p, p.status == .satisfied, !p.isExpensive else { return false }
        return p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet)
    }

    @MainActor
    private func updateBattery() {
        let state = UIDevice.current.batteryState
        lock.lock()
        // `.unknown` (simulator, monitoring off) does not block.
        pluggedIn = state != .unplugged
        lock.unlock()
    }

    private func releaseWaiters() {
        lock.lock()
        let waiters = pathWaiters
        pathWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
    }

    private func update(_ p: NWPath) {
        let signature = "\(p.status)|\(p.availableInterfaces.map(\.name).joined(separator: ","))|\(p.isExpensive)"
        lock.lock()
        path = p
        let changed = lastSignature != signature
        lastSignature = signature
        let callback = _onNetworkChange
        lock.unlock()
        releaseWaiters()
        if changed { callback?() }
    }
}

/// Resumes a continuation once, whoever comes first.
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?

    init(_ cont: CheckedContinuation<Void, Never>) { self.cont = cont }

    func resume() {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume()
    }
}
#endif

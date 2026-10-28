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
    private var observer: NSObjectProtocol?

    public init() {}

    /// Called on a network change (not on the first path report).
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

    /// Why a run must wait under `settings`, or nil when it may start.
    public func blocker(_ settings: EngineSettings) -> PauseReason? {
        lock.lock()
        let p = path
        let plugged = pluggedIn
        lock.unlock()
        if settings.wifiOnly, let p, p.status == .satisfied,
           p.isExpensive || !(p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet)) {
            return .wifiRequired
        }
        if settings.chargingOnly, !plugged { return .chargingRequired }
        return nil
    }

    @MainActor
    private func updateBattery() {
        let state = UIDevice.current.batteryState
        lock.lock()
        // `.unknown` (simulator, monitoring off) does not block.
        pluggedIn = state != .unplugged
        lock.unlock()
    }

    private func update(_ p: NWPath) {
        let signature = "\(p.status)|\(p.availableInterfaces.map(\.name).joined(separator: ","))|\(p.isExpensive)"
        lock.lock()
        path = p
        let changed = lastSignature != nil && lastSignature != signature
        lastSignature = signature
        let callback = _onNetworkChange
        lock.unlock()
        if changed { callback?() }
    }
}
#endif

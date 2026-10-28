import Flutter
import Foundation
import PicTunnelEngine
import PicTunnelPlatform

/// Engine → Flutter events (`EngineEventsApi`, M§3), throttled to at most 4 deliveries a second:
/// within a window the latest status wins and item changes are coalesced per item. Sends happen
/// on the main thread. Before Flutter is attached (a background launch) events are dropped; the
/// app asks for a fresh status when it starts.
final class EventsRelay: PicTunnelEngine.EngineEvents, @unchecked Sendable {
    private static let interval: TimeInterval = 0.25

    private let lock = NSLock()
    private var api: EngineEventsApi?
    private var pendingStatus: PicTunnelEngine.BackupStatus?
    private var pendingItems: [String: PicTunnelEngine.Item] = [:]
    private var itemOrder: [String] = []
    private var scheduled = false
    private var lastFlush = Date.distantPast

    func attach(_ api: EngineEventsApi) {
        lock.lock()
        self.api = api
        lock.unlock()
    }

    func status(_ s: PicTunnelEngine.BackupStatus) {
        lock.lock()
        pendingStatus = s
        lock.unlock()
        schedule()
    }

    func itemChanged(_ i: PicTunnelEngine.Item) {
        // The timeline shows assets; a Live Photo video or kept original changes no tile.
        guard !i.localId.contains("#") else { return }
        lock.lock()
        if pendingItems.updateValue(i, forKey: i.localId) == nil { itemOrder.append(i.localId) }
        lock.unlock()
        schedule()
    }

    func needsRepair() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let api = self.api
            self.lock.unlock()
            api?.onNeedsRepair { _ in }
        }
    }

    private func schedule() {
        lock.lock()
        guard !scheduled else {
            lock.unlock()
            return
        }
        scheduled = true
        let wait = max(0, Self.interval - Date().timeIntervalSince(lastFlush))
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.flush() }
    }

    private func flush() {
        lock.lock()
        let api = self.api
        let status = pendingStatus
        let items = itemOrder.compactMap { pendingItems[$0] }
        pendingStatus = nil
        pendingItems = [:]
        itemOrder = []
        scheduled = false
        lastFlush = Date()
        lock.unlock()
        guard let api else { return }
        if let status {
            api.onStatus(s: PigeonMapping.status(status, access: PhotoKitLibrary.access())) { _ in }
        }
        for i in items {
            api.onItemChanged(item: PigeonMapping.phoneItem(i)) { _ in }
        }
    }
}

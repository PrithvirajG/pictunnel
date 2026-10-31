#if os(iOS)
import Foundation
import PicTunnelEngine
import UserNotifications

/// Posts a local notification when backup pauses because the server is out of storage or the
/// quota is used up (spec §4), at most one per pause episode (`PauseAlerts`). The episode is kept
/// in `UserDefaults`, so a relaunch during the same pause posts nothing new.
///
/// It never asks for permission by itself at launch: the app calls `requestAuthorization()` when
/// the user starts backing up. Without permission nothing is posted.
public final class PauseNotifier: EngineEvents, @unchecked Sendable {
    private static let notifiedKey = "io.github.prithvirajg.pictunnel.pauseNotified"
    private static let requestId = "io.github.prithvirajg.pictunnel.pause"

    private let inner: any EngineEvents
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(forwardingTo inner: any EngineEvents, defaults: UserDefaults = .standard) {
        self.inner = inner
        self.defaults = defaults
    }

    /// Asks once for alert permission (later calls return what the user chose).
    public static func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Unpairing ends any episode.
    public func reset() {
        lock.lock()
        defaults.removeObject(forKey: Self.notifiedKey)
        lock.unlock()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.requestId])
    }

    // MARK: - EngineEvents

    public func status(_ s: BackupStatus) {
        lock.lock()
        let notified = defaults.string(forKey: Self.notifiedKey).flatMap(PauseReason.init(rawValue:))
        let decision = PauseAlerts.next(status: s, notified: notified)
        if decision.notified != notified {
            defaults.set(decision.notified?.rawValue, forKey: Self.notifiedKey)
        }
        lock.unlock()
        if let reason = decision.post { post(reason) }
        inner.status(s)
    }

    public func itemChanged(_ i: Item) { inner.itemChanged(i) }

    public func needsRepair() { inner.needsRepair() }

    private func post(_ reason: PauseReason) {
        let content = UNMutableNotificationContent()
        content.title = "Backup paused"
        switch reason {
        case .quota:
            content.body = "Your storage quota on the PicTunnel server is used up. Backup resumes when space is freed."
        default:
            content.body = "The PicTunnel server is out of storage. Backup resumes when space is freed."
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            center.add(UNNotificationRequest(identifier: Self.requestId, content: content, trigger: nil))
        }
    }
}
#endif

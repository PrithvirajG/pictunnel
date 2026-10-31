import Foundation

/// When a paused backup deserves a local notification (spec §4): the server is out of storage, or
/// this account's quota is used up. One notification per pause episode: the same pause seen again
/// (every status update repeats it) posts nothing, and the episode ends when backup is no longer
/// paused for that reason.
public enum PauseAlerts {
    public static let reasons: Set<PauseReason> = [.serverFull, .quota]

    /// Given a status and the reason already notified in the current episode (nil: none), returns
    /// the reason to notify now (nil: nothing to post) and the episode state to keep.
    public static func next(status: BackupStatus, notified: PauseReason?) -> (post: PauseReason?, notified: PauseReason?) {
        guard status.paused, let reason = status.pauseReason, reasons.contains(reason) else { return (nil, nil) }
        if notified == reason { return (nil, reason) }
        return (reason, reason)
    }
}

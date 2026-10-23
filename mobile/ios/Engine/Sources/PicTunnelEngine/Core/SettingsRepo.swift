import Foundation

/// Mirrors the Pigeon `EngineSettings`, plus the upload concurrency (R6: default 2, at most 4).
public struct EngineSettings: Equatable, Sendable {
    public static let defaultConcurrency = 2
    public static let maxConcurrency = 4

    public var wifiOnly = false
    public var chargingOnly = false
    public var includeVideos = true
    /// H3: also upload the unedited original of an edited asset, stacked with the current rendition.
    public var keepUneditedOriginals = false
    public var allAlbums = true
    public var albumIds: [String] = []
    public var uploadConcurrency = EngineSettings.defaultConcurrency

    public init() {}
}

/// A run-level pause. `untilMs` (wall clock) lets a server-caused pause be retried later; nil
/// waits for `SettingsRepo.clearPause`.
public struct PauseState: Equatable, Sendable {
    public var reason: PauseReason
    public var untilMs: Int64?

    public init(reason: PauseReason, untilMs: Int64?) {
        self.reason = reason
        self.untilMs = untilMs
    }
}

/// Engine settings and run state, as string pairs in the `settings` table.
public struct SettingsRepo: Sendable {
    private let db: EngineDB

    public init(db: EngineDB) { self.db = db }

    public func get() -> EngineSettings {
        let m = (try? db.allSettings()) ?? [:]
        var s = EngineSettings()
        func bool(_ k: String) -> Bool? { m[k].flatMap { Bool($0) } }
        if let v = bool(Keys.wifiOnly) { s.wifiOnly = v }
        if let v = bool(Keys.chargingOnly) { s.chargingOnly = v }
        if let v = bool(Keys.includeVideos) { s.includeVideos = v }
        if let v = bool(Keys.keepUnedited) { s.keepUneditedOriginals = v }
        if let v = bool(Keys.allAlbums) { s.allAlbums = v }
        if let v = m[Keys.albumIds] { s.albumIds = v.split(separator: "\n").map(String.init) }
        if let v = m[Keys.concurrency].flatMap({ Int($0) }) { s.uploadConcurrency = v }
        s.uploadConcurrency = min(max(s.uploadConcurrency, 1), EngineSettings.maxConcurrency)
        return s
    }

    public func set(_ s: EngineSettings) throws {
        try db.setSetting(Keys.wifiOnly, String(s.wifiOnly))
        try db.setSetting(Keys.chargingOnly, String(s.chargingOnly))
        try db.setSetting(Keys.includeVideos, String(s.includeVideos))
        try db.setSetting(Keys.keepUnedited, String(s.keepUneditedOriginals))
        try db.setSetting(Keys.allAlbums, String(s.allAlbums))
        try db.setSetting(Keys.albumIds, s.albumIds.joined(separator: "\n"))
        try db.setSetting(Keys.concurrency, String(min(max(s.uploadConcurrency, 1), EngineSettings.maxConcurrency)))
    }

    public func pause() -> PauseState? {
        guard let name = try? db.setting(Keys.pauseReason), let reason = PauseReason(rawValue: name) else { return nil }
        return PauseState(reason: reason, untilMs: (try? db.setting(Keys.pauseUntil)).flatMap { $0.flatMap { Int64($0) } })
    }

    public func setPause(_ p: PauseState) throws {
        try db.setSetting(Keys.pauseReason, p.reason.rawValue)
        if let until = p.untilMs { try db.setSetting(Keys.pauseUntil, String(until)) } else { try db.removeSetting(Keys.pauseUntil) }
    }

    public func clearPause() throws {
        try db.removeSetting(Keys.pauseReason)
        try db.removeSetting(Keys.pauseUntil)
    }

    public func lastRunAtMs() -> Int64? { (try? db.setting(Keys.lastRunAt)).flatMap { $0.flatMap { Int64($0) } } }

    public func setLastRunAtMs(_ ms: Int64) throws { try db.setSetting(Keys.lastRunAt, String(ms)) }

    private enum Keys {
        static let wifiOnly = "wifi_only"
        static let chargingOnly = "charging_only"
        static let includeVideos = "include_videos"
        static let keepUnedited = "keep_unedited_originals"
        static let allAlbums = "all_albums"
        static let albumIds = "album_ids"
        static let concurrency = "upload_concurrency"
        static let pauseReason = "pause_reason"
        static let pauseUntil = "pause_until_ms"
        static let lastRunAt = "last_run_at_ms"
    }
}

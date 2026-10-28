import Foundation
import PicTunnelEngine
import PicTunnelPlatform

// Every conversion between the Pigeon types (Pigeon.g.swift, compiled into this target, so its
// names shadow the engine's here) and the engine's own types (`PicTunnelEngine.X`) lives in this
// file, so a revision of mobile/pigeons/engine.dart only touches it.
//
// Written against the revised Pigeon API (Task 10): PhoneItem.filename, AttentionItem.sha256,
// BackupStatus.mediaAccess (MediaAccess full/partial/none) and
// PauseReason.serverCertificateChanged.

enum PigeonMapping {
    // MARK: enums

    static func itemState(_ s: PicTunnelEngine.ItemState) -> ItemState {
        switch s {
        case .discovered: return .discovered
        case .hashed: return .hashed
        case .queued: return .queued
        case .uploading: return .uploading
        case .verifying: return .verifying
        case .backedUp: return .backedUp
        case .skipped: return .skipped
        case .freed: return .freed
        case .needsAttention: return .needsAttention
        case .paused: return .paused
        }
    }

    static func pauseReason(_ r: PicTunnelEngine.PauseReason) -> PauseReason {
        switch r {
        case .user: return .user
        case .wifiRequired: return .wifiRequired
        case .chargingRequired: return .chargingRequired
        case .serverFull: return .serverFull
        case .quota: return .quota
        case .clientTooOld: return .clientTooOld
        case .permission: return .permission
        case .serverCertificateChanged: return .serverCertificateChanged
        }
    }

    static func pauseReason(_ r: PauseReason) -> PicTunnelEngine.PauseReason {
        switch r {
        case .user: return .user
        case .wifiRequired: return .wifiRequired
        case .chargingRequired: return .chargingRequired
        case .serverFull: return .serverFull
        case .quota: return .quota
        case .clientTooOld: return .clientTooOld
        case .permission: return .permission
        case .serverCertificateChanged: return .serverCertificateChanged
        }
    }

    /// PhotoKit `.limited` is the app's "partial" access (back up the selected photos only).
    static func mediaAccess(_ a: PhotoAccess) -> MediaAccess {
        switch a {
        case .full: return .full
        case .limited: return .partial
        case .denied, .notDetermined: return MediaAccess.none
        }
    }

    // MARK: status and settings

    static func status(_ s: PicTunnelEngine.BackupStatus, access: PhotoAccess) -> BackupStatus {
        BackupStatus(
            backedUp: Int64(s.backedUp), total: Int64(s.total), queued: Int64(s.queued),
            uploading: s.uploading.map(progress), needsAttention: Int64(s.needsAttention), skipped: Int64(s.skipped),
            freeableBytes: s.freeableBytes, paused: s.paused, pauseReason: s.pauseReason.map(pauseReason),
            lastRunAtMs: s.lastRunAtMs, preparing: Int64(s.preparing), mediaAccess: mediaAccess(access))
    }

    /// The status before pairing: nothing indexed.
    static func emptyStatus(access: PhotoAccess) -> BackupStatus {
        BackupStatus(backedUp: 0, total: 0, queued: 0, uploading: nil, needsAttention: 0, skipped: 0, freeableBytes: 0,
                     paused: false, pauseReason: nil, lastRunAtMs: nil, preparing: 0, mediaAccess: mediaAccess(access))
    }

    static func progress(_ p: PicTunnelEngine.UploadProgress) -> UploadProgress {
        UploadProgress(localId: p.localId, filename: p.filename, sentBytes: p.sentBytes, totalBytes: p.totalBytes,
                       bytesPerSecond: p.bytesPerSecond)
    }

    static func settings(_ s: PicTunnelEngine.EngineSettings) -> EngineSettings {
        EngineSettings(wifiOnly: s.wifiOnly, chargingOnly: s.chargingOnly, includeVideos: s.includeVideos,
                       keepUneditedOriginals: s.keepUneditedOriginals, allAlbums: s.allAlbums, albumIds: s.albumIds)
    }

    /// The bridge has no upload concurrency; it keeps the engine's current value.
    static func settings(_ s: EngineSettings, keeping current: PicTunnelEngine.EngineSettings) -> PicTunnelEngine.EngineSettings {
        var out = current
        out.wifiOnly = s.wifiOnly
        out.chargingOnly = s.chargingOnly
        out.includeVideos = s.includeVideos
        out.keepUneditedOriginals = s.keepUneditedOriginals
        out.allAlbums = s.allAlbums
        out.albumIds = s.albumIds
        return out
    }

    // MARK: items and lists

    static func phoneItem(_ i: PicTunnelEngine.Item) -> PhoneItem {
        PhoneItem(localId: i.localId, filename: i.filename, sha256: i.sha256, takenAtMs: i.takenAtMs, mime: i.mime,
                  size: i.size, width: i.width, height: i.height, durationMs: i.durationMs, state: itemState(i.state),
                  assetId: i.assetId, isLivePhoto: i.kind == .livePhoto)
    }

    static func page(_ p: PicTunnelEngine.PhoneItemPage) -> PhoneItemPage {
        PhoneItemPage(items: p.items.map(phoneItem), nextKey: p.nextKey)
    }

    static func attention(_ a: PicTunnelEngine.AttentionItem) -> AttentionItem {
        AttentionItem(localId: a.localId, filename: a.filename, code: a.code, message: a.message,
                      attempts: Int64(a.attempts), sha256: a.sha256)
    }

    static func activity(_ e: PicTunnelEngine.ActivityEntry) -> ActivityEntry {
        ActivityEntry(atMs: e.atMs, kind: e.kind, message: e.message, localId: e.localId)
    }

    static func freeUp(_ r: PicTunnelEngine.FreeUpResult) -> FreeUpResult {
        FreeUpResult(freedCount: Int64(r.freedCount), freedBytes: r.freedBytes,
                     skipped: r.skipped.map { SkippedFree(localId: $0.localId, reason: $0.reason) })
    }

    static func album(_ a: PhotoAlbum) -> AlbumInfo {
        AlbumInfo(id: a.id, name: a.name, count: Int64(a.count))
    }

    // MARK: pairing

    static func pairInput(_ r: PairRequest) -> PairInput {
        PairInput(qrUri: r.qrUri, serverUrl: r.serverUrl, code: r.code, deviceName: r.deviceName, pinnedFp: r.pinnedFp)
    }

    static func pairResult(_ p: Paired) -> PairResult {
        PairResult(serverId: p.serverId, serverName: p.serverName, userName: p.userName, deviceId: p.deviceId)
    }

    static func identity(_ f: ServerFingerprint) -> ServerIdentity {
        ServerIdentity(serverId: f.serverId, name: f.name, fp16: f.fp16, fpFull: f.fpFull, url: f.url)
    }

    static func connection(_ c: RuntimeConnection) -> ServerConnection {
        ServerConnection(serverId: c.serverId, name: c.name, activeEndpoint: c.activeEndpoint, onLan: c.onLan, fp16: c.fp16)
    }

    // MARK: errors

    /// The `PlatformException.code` the app reads: pairing codes as they are (`pin_mismatch`,
    /// `pairing_code_invalid`, `unreachable`, …), then engine states.
    static func error(_ e: Error) -> PigeonError {
        switch e {
        case let p as PairingError:
            return PigeonError(code: p.code, message: p.message.isEmpty ? p.code : p.message, details: nil)
        case let r as RuntimeError:
            switch r {
            case .notPaired: return PigeonError(code: "not_paired", message: "This phone is not paired", details: nil)
            case .needsRepair: return PigeonError(code: "needs_repair", message: "Pair this phone again", details: nil)
            case .transient: return PigeonError(code: "unreachable", message: "The server could not be reached", details: nil)
            }
        case let d as DownloadError:
            return PigeonError(code: d.code, message: "The download failed (\(d.code))", details: nil)
        case let p as PigeonError:
            return p
        default:
            return PigeonError(code: "engine_error", message: "\(e)", details: nil)
        }
    }
}

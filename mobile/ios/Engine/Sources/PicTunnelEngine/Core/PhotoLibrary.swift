import Foundation

/// Which `PHAssetResource` of an asset an item row stands for (H3, H4):
/// - `primary`: the current rendition (`fullSizePhoto`/`fullSizeVideo` when edited, else
///   `photo`/`video`). A Live Photo's primary is its still.
/// - `liveVideo`: a Live Photo's paired video (`fullSizePairedVideo`/`pairedVideo`), uploaded
///   after the still with `pair_role=live_video`.
/// - `original`: the unedited `photo`/`video` of an edited asset, only with "also keep unedited
///   originals"; uploaded as its own asset stacked with the primary (`stack_key`).
public enum ResourceRole: String, CaseIterable, Sendable {
    case primary
    case liveVideo = "live_video"
    case original
}

/// The item row for one resource. The primary's row id is the asset's `localIdentifier`; the
/// other resources append `#<role>`, so a row id with no `#` is an asset (PhotoKit identifiers
/// never contain `#`). The row id is also the `local_id` sent to the server.
public struct ItemRef: Equatable, Hashable, Sendable {
    public var assetLocalId: String
    public var role: ResourceRole

    public init(assetLocalId: String, role: ResourceRole) {
        self.assetLocalId = assetLocalId
        self.role = role
    }

    public init(rowId: String) {
        if let hash = rowId.lastIndex(of: "#"), let role = ResourceRole(rawValue: String(rowId[rowId.index(after: hash)...])) {
            self.init(assetLocalId: String(rowId[..<hash]), role: role)
        } else {
            self.init(assetLocalId: rowId, role: .primary)
        }
    }

    public var rowId: String { role == .primary ? assetLocalId : "\(assetLocalId)#\(role.rawValue)" }
}

/// One resource of a new or changed asset, as the library sees it.
public struct LibraryResource: Equatable, Sendable {
    public var assetLocalId: String
    public var role: ResourceRole
    /// The resource's byte size (part of the R3 fingerprint).
    public var size: Int64
    /// The asset's modification date (part of the R3 fingerprint); an edit changes it.
    public var modifiedAtMs: Int64
    public var takenAtMs: Int64
    public var mime: String
    /// The asset's kind; a Live Photo's paired video is `video`.
    public var kind: ItemKind
    /// `PHAssetResource.originalFilename`.
    public var filename: String
    public var width: Int64?
    public var height: Int64?
    public var durationMs: Int64?

    public init(assetLocalId: String, role: ResourceRole, size: Int64, modifiedAtMs: Int64, takenAtMs: Int64,
                mime: String, kind: ItemKind, filename: String, width: Int64? = nil, height: Int64? = nil,
                durationMs: Int64? = nil) {
        self.assetLocalId = assetLocalId
        self.role = role
        self.size = size
        self.modifiedAtMs = modifiedAtMs
        self.takenAtMs = takenAtMs
        self.mime = mime
        self.kind = kind
        self.filename = filename
        self.width = width
        self.height = height
        self.durationMs = durationMs
    }
}

/// The result of one scan (M§4.2). `changed` holds every resource of each new or changed asset;
/// `removedAssets` the asset ids deleted from the phone. With `fullRescan` (first scan, or the
/// change token expired), `changed` is the whole library and anything indexed but missing from it
/// is dropped from the index too. Deletions on the phone are never sent to the server (R8).
public struct LibraryScan: Sendable {
    public var changed: [LibraryResource]
    public var removedAssets: [String]
    /// The archived `PHPersistentChangeToken` to pass next time.
    public var token: Data?
    public var fullRescan: Bool

    public init(changed: [LibraryResource], removedAssets: [String], token: Data?, fullRescan: Bool) {
        self.changed = changed
        self.removedAssets = removedAssets
        self.token = token
        self.fullRescan = fullRescan
    }
}

/// The local file identity that keys the hash cache (R3) and guards free-up-space (P§7.8).
public struct Fingerprint: Equatable, Sendable {
    public var modifiedAtMs: Int64
    public var size: Int64

    public init(modifiedAtMs: Int64, size: Int64) {
        self.modifiedAtMs = modifiedAtMs
        self.size = size
    }
}

/// A resource written to staging, hashed while it was written (M§6: the file is read once).
public struct ExportedResource: Equatable, Sendable {
    public var file: URL
    public var size: Int64
    public var sha256: String

    public init(file: URL, size: Int64, sha256: String) {
        self.file = file
        self.size = size
        self.sha256 = sha256
    }
}

/// PhotoKit behind a protocol (M§6; the device implementation is Task 14).
public protocol PhotoLibrary: Sendable {
    /// Changes since `token` (nil: a full scan). Applies the album selection and the include-videos
    /// setting, and reports `original` resources for edited assets (the engine drops them unless
    /// "also keep unedited originals" is on).
    ///
    /// Returns nil, without reading the library, when only a full scan is possible (no token, an
    /// expired one, limited access) and `allowFullRescan` is false. Throws `CancellationError`
    /// promptly when the calling task is cancelled.
    func scan(since token: Data?, settings: EngineSettings, allowFullRescan: Bool) async throws -> LibraryScan?

    /// The resource's current fingerprint, or nil when the asset or resource no longer exists.
    func fingerprint(assetLocalId: String, role: ResourceRole) async -> Fingerprint?

    /// Writes the resource's exact bytes (H1) to `file` (`PHAssetResourceManager.writeData`),
    /// hashing them on the way, and returns the size and SHA-256.
    func exportResource(assetLocalId: String, role: ResourceRole, to file: URL) async throws -> ExportedResource
}

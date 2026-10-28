#if os(iOS)
import Foundation
import Photos
import PicTunnelEngine
import UIKit
import UniformTypeIdentifiers

/// The app's photo library authorization, as backup sees it (M§4.6). With `limited` access only
/// the photos the user selected are visible, so only those are backed up.
public enum PhotoAccess: Equatable, Sendable {
    case full
    case limited
    case denied
    case notDetermined
}

public enum PhotoLibraryError: Error {
    /// No read access: nothing may be scanned (a scan of nothing would drop the whole index).
    case accessDenied
    case assetGone
    case resourceGone
    case thumbnailUnavailable
    case writeFailed
}

/// An album offered for "back up selected albums".
public struct PhotoAlbum: Equatable, Sendable {
    public var id: String
    public var name: String
    public var count: Int
}

/// `PhotoLibrary` over PhotoKit (M§4.2, M§6, H1, H3, H4).
///
/// - Scans are incremental with `PHPersistentChangeToken`: only inserted and updated assets are
///   read, deletions drop rows from the index. An expired token (or limited access, whose
///   selection changes are not reported as library changes) means a full rescan.
/// - Each asset becomes one row per role (`ResourceSelection`): the current rendition, a Live
///   Photo's paired video, and an edited asset's unedited original.
/// - Sizes are the exact resource byte counts (`PHAssetResource` `fileSize`), the size an export
///   writes, so the R3 fingerprint and the free-up guard (P§7.8) compare like with like. When
///   PhotoKit does not report it, the bytes are counted once (and remembered for that rendition).
/// - Exports stream `PHAssetResourceManager.requestData` into the staging file and hash on the
///   way, so the bytes are read once (iCloud originals are downloaded as needed).
public final class PhotoKitLibrary: PhotoLibrary, @unchecked Sendable {
    private let lock = NSLock()
    private var measured: [String: Int64] = [:]

    public init() {}

    // MARK: - access

    public static func access() -> PhotoAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .full
        case .limited: return .limited
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    /// Asks for read/write access when it was never asked; returns the resulting access.
    public static func requestAccess() async -> PhotoAccess {
        if access() == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return access()
    }

    // MARK: - scan

    public func scan(since token: Data?, settings: EngineSettings) async throws -> LibraryScan {
        let access = Self.access()
        guard access == .full || access == .limited else { throw PhotoLibraryError.accessDenied }
        let library = PHPhotoLibrary.shared()
        // Taken before reading, so a change made while scanning is reported again next time.
        let next = try? NSKeyedArchiver.archivedData(withRootObject: library.currentChangeToken, requiringSecureCoding: true)
        if access == .full, let token,
           let old = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: token),
           let inc = try? await incremental(since: old, settings: settings) {
            return LibraryScan(changed: inc.changed, removedAssets: inc.removed, token: next, fullRescan: false)
        }
        var changed: [LibraryResource] = []
        for asset in scopedAssets(settings) {
            changed += await resources(of: asset)
        }
        return LibraryScan(changed: changed, removedAssets: [], token: next, fullRescan: true)
    }

    private struct ScopeChanged: Error {}

    private func incremental(since token: PHPersistentChangeToken, settings: EngineSettings)
        async throws -> (changed: [LibraryResource], removed: [String]) {
        let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
        var touched = Set<String>()
        var removed = Set<String>()
        let albums = Set(settings.albumIds)
        for change in changes {
            let details = try change.changeDetails(for: .asset)
            touched.formUnion(details.insertedLocalIdentifiers)
            touched.formUnion(details.updatedLocalIdentifiers)
            removed.formUnion(details.deletedLocalIdentifiers)
            if !settings.allAlbums, let c = try? change.changeDetails(for: .assetCollection) {
                // A selected album gained or lost photos: membership is not an asset change.
                let ids = c.updatedLocalIdentifiers.union(c.deletedLocalIdentifiers).union(c.insertedLocalIdentifiers)
                if !albums.isDisjoint(with: ids) { throw ScopeChanged() }
            }
        }
        touched.subtract(removed)
        guard !touched.isEmpty else { return ([], Array(removed)) }

        let inScope: Set<String>? = settings.allAlbums ? nil : Set(scopedAssets(settings).map(\.localIdentifier))
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(touched), options: Self.fetchOptions(settings))
        var seen = Set<String>()
        var changed: [LibraryResource] = []
        var assets: [PHAsset] = []
        fetched.enumerateObjects { a, _, _ in assets.append(a) }
        for a in assets {
            seen.insert(a.localIdentifier)
            if let inScope, !inScope.contains(a.localIdentifier) {
                removed.insert(a.localIdentifier)
                continue
            }
            changed += await resources(of: a)
        }
        // Changed assets that are no longer in scope (hidden, or a video with videos excluded).
        removed.formUnion(touched.subtracting(seen))
        return (changed, Array(removed))
    }

    private static func fetchOptions(_ settings: EngineSettings) -> PHFetchOptions {
        let o = PHFetchOptions()
        o.includeHiddenAssets = false
        if settings.includeVideos {
            o.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                      PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        } else {
            o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        return o
    }

    /// Every asset in scope: the whole library, or the selected albums.
    private func scopedAssets(_ settings: EngineSettings) -> [PHAsset] {
        let options = Self.fetchOptions(settings)
        var out: [PHAsset] = []
        if settings.allAlbums {
            PHAsset.fetchAssets(with: options).enumerateObjects { a, _, _ in out.append(a) }
            return out
        }
        var seen = Set<String>()
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: settings.albumIds, options: nil)
        collections.enumerateObjects { c, _, _ in
            PHAsset.fetchAssets(in: c, options: options).enumerateObjects { a, _, _ in
                if seen.insert(a.localIdentifier).inserted { out.append(a) }
            }
        }
        return out
    }

    private func resources(of asset: PHAsset) async -> [LibraryResource] {
        let media = Self.media(asset)
        let live = asset.mediaSubtypes.contains(.photoLive)
        let all = PHAssetResource.assetResources(for: asset).map(PHResource.init)
        var out: [LibraryResource] = []
        for (role, r) in ResourceSelection.select(all, media: media, isLivePhoto: live) {
            guard let size = await size(of: r.resource, asset: asset, role: role) else { continue }
            out.append(LibraryResource(
                assetLocalId: asset.localIdentifier, role: role, size: size,
                modifiedAtMs: Self.modifiedAtMs(asset), takenAtMs: Self.ms(asset.creationDate ?? asset.modificationDate),
                mime: Self.mime(r.resource), kind: ResourceSelection.itemKind(role: role, media: media, isLivePhoto: live),
                filename: r.originalFilename, width: Int64(asset.pixelWidth), height: Int64(asset.pixelHeight),
                durationMs: media == .video && role != .liveVideo ? Int64((asset.duration * 1000).rounded()) : nil))
        }
        return out
    }

    // MARK: - fingerprint and export

    public func fingerprint(assetLocalId: String, role: ResourceRole) async -> Fingerprint? {
        guard let found = locate(assetLocalId, role),
              let size = await size(of: found.resource, asset: found.asset, role: role) else {
            return nil
        }
        return Fingerprint(modifiedAtMs: Self.modifiedAtMs(found.asset), size: size)
    }

    public func exportResource(assetLocalId: String, role: ResourceRole, to file: URL) async throws -> ExportedResource {
        guard let r = locate(assetLocalId, role)?.resource else { throw PhotoLibraryError.resourceGone }
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw PhotoLibraryError.writeFailed }
        let handle = try FileHandle(forWritingTo: file)
        let sink = ExportSink(handle: handle)
        do {
            try await Self.stream(r) { sink.write($0) }
            try sink.finish()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return ExportedResource(file: file, size: sink.count, sha256: sink.hex)
    }

    /// Streams a resource's bytes (downloading from iCloud when needed). Cancelling the calling
    /// task cancels the request.
    private static func stream(_ r: PHAssetResource, _ receive: @escaping (Data) -> Void) async throws {
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let request = RequestBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let id = manager.requestData(for: r, options: options, dataReceivedHandler: receive) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
                request.set(id, manager)
            }
        } onCancel: {
            request.cancel()
        }
    }

    // MARK: - thumbnails and albums

    /// A JPEG thumbnail of the asset behind `localId` (a row id), at least `sizePx` on its short side.
    public func thumbnail(localId: String, sizePx: Int) async throws -> Data {
        guard let asset = Self.asset(ItemRef(rowId: localId).assetLocalId) else { throw PhotoLibraryError.assetGone }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let px = CGFloat(max(sizePx, 16))
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: px, height: px),
                                                  contentMode: .aspectFill, options: options) { image, _ in
                if let data = image?.jpegData(compressionQuality: 0.8) {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: PhotoLibraryError.thumbnailUnavailable)
                }
            }
        }
    }

    /// User albums and smart albums (without hidden and recently deleted) that hold something.
    public func albums() -> [PhotoAlbum] {
        var out: [PhotoAlbum] = []
        func add(_ result: PHFetchResult<PHAssetCollection>) {
            result.enumerateObjects { c, _, _ in
                // 1000000201 is "Recently Deleted", which has no public subtype constant.
                if c.assetCollectionSubtype == .smartAlbumAllHidden || c.assetCollectionSubtype.rawValue == 1_000_000_201 {
                    return
                }
                let n = PHAsset.fetchAssets(in: c, options: nil).count
                if n > 0 { out.append(PhotoAlbum(id: c.localIdentifier, name: c.localizedTitle ?? "Album", count: n)) }
            }
        }
        add(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil))
        add(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))
        return out
    }

    // MARK: - helpers

    private static func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private func locate(_ assetLocalId: String, _ role: ResourceRole) -> (asset: PHAsset, resource: PHAssetResource)? {
        guard let asset = Self.asset(assetLocalId) else { return nil }
        let all = PHAssetResource.assetResources(for: asset).map(PHResource.init)
        guard let r = ResourceSelection.resource(for: role, in: all, media: Self.media(asset),
                                                 isLivePhoto: asset.mediaSubtypes.contains(.photoLive)) else { return nil }
        return (asset, r.resource)
    }

    /// The exact byte size of a resource.
    private func size(of r: PHAssetResource, asset: PHAsset, role: ResourceRole) async -> Int64? {
        if let n = (r.value(forKey: "fileSize") as? NSNumber)?.int64Value, n >= 0 { return n }
        let key = "\(asset.localIdentifier)#\(role.rawValue)@\(Self.modifiedAtMs(asset))"
        lock.lock()
        let known = measured[key]
        lock.unlock()
        if let known { return known }
        let counter = ByteCounter()
        do {
            try await Self.stream(r) { counter.add($0.count) }
        } catch {
            return nil
        }
        lock.lock()
        measured[key] = counter.value
        lock.unlock()
        return counter.value
    }

    private static func media(_ asset: PHAsset) -> AssetMediaKind {
        switch asset.mediaType {
        case .image: return .image
        case .video: return .video
        default: return .other
        }
    }

    private static func modifiedAtMs(_ asset: PHAsset) -> Int64 { ms(asset.modificationDate ?? asset.creationDate) }

    private static func ms(_ date: Date?) -> Int64 { Int64(((date?.timeIntervalSince1970 ?? 0) * 1000).rounded()) }

    private static func mime(_ r: PHAssetResource) -> String {
        if let t = UTType(r.uniformTypeIdentifier)?.preferredMIMEType { return t }
        return ResourceSelection.mime(uti: r.uniformTypeIdentifier, filename: r.originalFilename)
    }
}

/// `PHAssetResource` as role selection sees it.
struct PHResource: AssetResourceAdapter {
    let resource: PHAssetResource

    var resourceKind: AssetResourceKind {
        switch resource.type {
        case .photo: return .photo
        case .video: return .video
        case .fullSizePhoto: return .fullSizePhoto
        case .fullSizeVideo: return .fullSizeVideo
        case .pairedVideo: return .pairedVideo
        case .fullSizePairedVideo: return .fullSizePairedVideo
        default: return .other
        }
    }

    var originalFilename: String { resource.originalFilename }
    var uniformTypeIdentifier: String { resource.uniformTypeIdentifier }
}

/// Writes and hashes export chunks (PhotoKit delivers them serially, on its own queue).
private final class ExportSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var hasher = SHA256Stream()
    private var error: Error?
    private(set) var count: Int64 = 0
    private(set) var hex = ""

    init(handle: FileHandle) { self.handle = handle }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard error == nil else { return }
        do {
            try handle.write(contentsOf: data)
            hasher.update(data)
            count += Int64(data.count)
        } catch {
            self.error = error
        }
    }

    func finish() throws {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        try handle.synchronize()
        try handle.close()
        hex = hasher.finalizeHex()
    }
}

private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n: Int64 = 0
    func add(_ k: Int) { lock.lock(); n += Int64(k); lock.unlock() }
    var value: Int64 { lock.lock(); defer { lock.unlock() }; return n }
}

/// A data request that can be cancelled before or after it starts.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHAssetResourceDataRequestID?
    private var manager: PHAssetResourceManager?
    private var cancelled = false

    func set(_ id: PHAssetResourceDataRequestID, _ manager: PHAssetResourceManager) {
        lock.lock()
        self.id = id
        self.manager = manager
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { manager.cancelDataRequest(id) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let id = self.id
        let manager = self.manager
        lock.unlock()
        if let id, let manager { manager.cancelDataRequest(id) }
    }
}
#endif

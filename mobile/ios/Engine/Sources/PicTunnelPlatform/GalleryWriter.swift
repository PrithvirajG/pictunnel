#if os(iOS)
import Foundation
import Photos
import PicTunnelEngine

/// `saveToGallery` (M§3): downloads an original from the server and adds it to the photo library.
/// The download goes to a temporary file first (ranged requests, bounded memory) and is moved into
/// the library in one change, so the library never sees a half-written file. Returns the new
/// asset's local identifier; the next scan indexes it and check finds it already backed up.
public struct GalleryWriter {
    private let runtime: EngineRuntime
    private let tmpDir: URL

    public init(runtime: EngineRuntime, tmpDir: URL) {
        self.runtime = runtime
        self.tmpDir = tmpDir
    }

    public enum GalleryError: Error {
        case notAMedia(String)
        case notPaired
        case noPlaceholder
    }

    public func save(assetId: String, filename: String, mime: String) async throws -> String {
        let type: PHAssetResourceType
        if mime.hasPrefix("image/") {
            type = .photo
        } else if mime.hasPrefix("video/") {
            type = .video
        } else {
            throw GalleryError.notAMedia(mime)
        }
        guard let client = runtime.client() else { throw GalleryError.notPaired }
        let fm = FileManager.default
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let ext = (filename as NSString).pathExtension
        let file = tmpDir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
        defer { try? fm.removeItem(at: file) }
        _ = try await client.downloadOriginal(assetId: assetId, to: file)

        let created = Placeholder()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            options.shouldMoveFile = true
            request.addResource(with: type, fileURL: file, options: options)
            created.id = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let id = created.id else { throw GalleryError.noPlaceholder }
        return id
    }
}

private final class Placeholder: @unchecked Sendable {
    var id: String?
}
#endif

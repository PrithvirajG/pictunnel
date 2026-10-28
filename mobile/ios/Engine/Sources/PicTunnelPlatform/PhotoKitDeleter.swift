#if os(iOS)
import Foundation
import Photos
import PicTunnelEngine

/// Free up space's delete step (M§4.5): `PHAssetChangeRequest.deleteAssets`, which always shows
/// the system confirmation. Returns the assets that are gone afterwards; a cancelled dialog (or
/// any failure) returns none, so nothing is marked `Freed` that is still on the phone.
public struct PhotoKitDeleter: Deleter {
    public init() {}

    public func delete(_ localIds: [String]) async -> Set<String> {
        guard !localIds.isEmpty else { return [] }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIds, options: nil)
        var existing = Set<String>()
        assets.enumerateObjects { a, _, _ in existing.insert(a.localIdentifier) }
        guard !existing.isEmpty else { return [] }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch {
            return []
        }
        var remaining = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: Array(existing), options: nil).enumerateObjects { a, _, _ in
            remaining.insert(a.localIdentifier)
        }
        return existing.subtracting(remaining)
    }
}
#endif

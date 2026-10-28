import Foundation

/// The `PHAssetResourceType` values role selection cares about, by meaning (the PhotoKit adapter
/// maps the real enum onto these, so the rules below run and are tested without PhotoKit).
public enum AssetResourceKind: Equatable, Sendable {
    case photo
    case video
    case fullSizePhoto
    case fullSizeVideo
    case pairedVideo
    case fullSizePairedVideo
    /// Anything else (alternate photo, audio, adjustment data, adjustment bases, proxies).
    case other
}

/// `PHAssetMediaType`, by meaning.
public enum AssetMediaKind: Equatable, Sendable {
    case image
    case video
    case other
}

/// One `PHAssetResource`, as role selection sees it.
public protocol AssetResourceAdapter {
    var resourceKind: AssetResourceKind { get }
    var originalFilename: String { get }
    /// `PHAssetResource.uniformTypeIdentifier`.
    var uniformTypeIdentifier: String { get }
}

/// Which resource of an asset each item row uploads (H3, H4, M§6):
/// - `primary`: the current rendition, `fullSizePhoto`/`fullSizeVideo` when the asset was edited,
///   else `photo`/`video`. A Live Photo's primary is its still.
/// - `liveVideo`: a Live Photo's paired video, the edited `fullSizePairedVideo` when present, else
///   `pairedVideo`.
/// - `original`: only for an edited asset, its unedited `photo`/`video` (uploaded when "also keep
///   unedited originals" is on; the engine drops it otherwise).
public enum ResourceSelection {
    /// The roles present for an asset, primary first. Empty when the asset has nothing to back up
    /// (no primary resource, or a media type other than image or video).
    public static func select<R: AssetResourceAdapter>(_ resources: [R], media: AssetMediaKind,
                                                       isLivePhoto: Bool) -> [(role: ResourceRole, resource: R)] {
        guard media != .other, let primary = resource(for: .primary, in: resources, media: media, isLivePhoto: isLivePhoto) else {
            return []
        }
        var out: [(role: ResourceRole, resource: R)] = [(.primary, primary)]
        if let live = resource(for: .liveVideo, in: resources, media: media, isLivePhoto: isLivePhoto) {
            out.append((.liveVideo, live))
        }
        if let original = resource(for: .original, in: resources, media: media, isLivePhoto: isLivePhoto) {
            out.append((.original, original))
        }
        return out
    }

    /// The resource standing for `role`, or nil when the asset has none.
    public static func resource<R: AssetResourceAdapter>(for role: ResourceRole, in resources: [R], media: AssetMediaKind,
                                                         isLivePhoto: Bool) -> R? {
        func first(_ k: AssetResourceKind) -> R? { resources.first { $0.resourceKind == k } }
        let (edited, base): (AssetResourceKind, AssetResourceKind)
        switch media {
        case .image: (edited, base) = (.fullSizePhoto, .photo)
        case .video: (edited, base) = (.fullSizeVideo, .video)
        case .other: return nil
        }
        switch role {
        case .primary:
            return first(edited) ?? first(base)
        case .liveVideo:
            guard media == .image, isLivePhoto else { return nil }
            return first(.fullSizePairedVideo) ?? first(.pairedVideo)
        case .original:
            guard first(edited) != nil else { return nil }
            return first(base)
        }
    }

    /// The item kind of a role's row: a Live Photo's still is `live_photo`, its video `video`.
    public static func itemKind(role: ResourceRole, media: AssetMediaKind, isLivePhoto: Bool) -> ItemKind {
        switch role {
        case .primary: media == .video ? .video : (isLivePhoto ? .livePhoto : .photo)
        case .liveVideo: .video
        case .original: media == .video ? .video : .photo
        }
    }

    /// The MIME type of a resource from its UTI, then its file extension.
    public static func mime(uti: String, filename: String) -> String {
        if let m = utiMime[uti.lowercased()] { return m }
        let ext = (filename as NSString).pathExtension.lowercased()
        return extMime[ext] ?? "application/octet-stream"
    }

    static let utiMime: [String: String] = [
        "public.jpeg": "image/jpeg",
        "public.heic": "image/heic",
        "public.heif": "image/heif",
        "public.png": "image/png",
        "com.compuserve.gif": "image/gif",
        "public.tiff": "image/tiff",
        "org.webmproject.webp": "image/webp",
        "com.adobe.raw-image": "image/x-adobe-dng",
        "com.apple.quicktime-movie": "video/quicktime",
        "public.mpeg-4": "video/mp4",
        "com.apple.m4v-video": "video/x-m4v",
        "public.avi": "video/x-msvideo",
        "public.3gpp": "video/3gpp",
    ]

    static let extMime: [String: String] = [
        "jpg": "image/jpeg", "jpeg": "image/jpeg", "heic": "image/heic", "heif": "image/heif",
        "png": "image/png", "gif": "image/gif", "tif": "image/tiff", "tiff": "image/tiff",
        "webp": "image/webp", "dng": "image/x-adobe-dng",
        "mov": "video/quicktime", "mp4": "video/mp4", "m4v": "video/x-m4v", "avi": "video/x-msvideo",
        "3gp": "video/3gpp",
    ]
}

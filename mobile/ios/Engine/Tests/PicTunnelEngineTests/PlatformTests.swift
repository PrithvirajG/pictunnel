import Foundation
import XCTest
@testable import PicTunnelEngine

/// The PhotoKit resource-role selection (H3, H4, M§6), run against an injected stand-in for
/// `PHAssetResource`. The rules are platform independent, so this runs everywhere; the PhotoKit
/// adapter itself (`PicTunnelPlatform`) only maps `PHAssetResourceType` onto `AssetResourceKind`.
final class PlatformTests: XCTestCase {
    private struct Res: AssetResourceAdapter, Equatable {
        var resourceKind: AssetResourceKind
        var originalFilename: String
        var uniformTypeIdentifier: String
    }

    private let photo = Res(resourceKind: .photo, originalFilename: "IMG_0001.HEIC", uniformTypeIdentifier: "public.heic")
    private let edited = Res(resourceKind: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", uniformTypeIdentifier: "public.jpeg")
    private let video = Res(resourceKind: .video, originalFilename: "IMG_0002.MOV", uniformTypeIdentifier: "com.apple.quicktime-movie")
    private let editedVideo = Res(resourceKind: .fullSizeVideo, originalFilename: "FullSizeRender.mov",
                                  uniformTypeIdentifier: "com.apple.quicktime-movie")
    private let paired = Res(resourceKind: .pairedVideo, originalFilename: "IMG_0001.MOV", uniformTypeIdentifier: "com.apple.quicktime-movie")
    private let editedPaired = Res(resourceKind: .fullSizePairedVideo, originalFilename: "FullSizeRender.mov",
                                   uniformTypeIdentifier: "com.apple.quicktime-movie")
    private let adjustments = Res(resourceKind: .other, originalFilename: "Adjustments.plist", uniformTypeIdentifier: "com.apple.property-list")

    private func roles(_ r: [Res], _ media: AssetMediaKind, live: Bool = false) -> [String] {
        ResourceSelection.select(r, media: media, isLivePhoto: live).map { "\($0.role.rawValue)=\($0.resource.originalFilename)" }
    }

    func testUneditedPhotoIsItsPhotoResource() {
        XCTAssertEqual(roles([photo], .image), ["primary=IMG_0001.HEIC"])
    }

    func testEditedPhotoUploadsTheCurrentRenditionAndOffersTheOriginal() {
        // H3: fullSizePhoto is the current rendition; the unedited photo is the `original` role.
        XCTAssertEqual(roles([photo, adjustments, edited], .image),
                       ["primary=FullSizeRender.jpg", "original=IMG_0001.HEIC"])
        XCTAssertEqual(roles([video, editedVideo], .video), ["primary=FullSizeRender.mov", "original=IMG_0002.MOV"])
    }

    func testLivePhotoPairsTheStillWithItsVideo() {
        // H4: the still is primary; the paired video follows, the edited one when present.
        XCTAssertEqual(roles([photo, paired], .image, live: true), ["primary=IMG_0001.HEIC", "live_video=IMG_0001.MOV"])
        XCTAssertEqual(roles([photo, paired, edited, editedPaired], .image, live: true),
                       ["primary=FullSizeRender.jpg", "live_video=FullSizeRender.mov", "original=IMG_0001.HEIC"])
        XCTAssertEqual(roles([photo, paired], .image, live: false), ["primary=IMG_0001.HEIC"],
                       "a paired video only counts for a Live Photo")
    }

    func testNothingToBackUp() {
        XCTAssertEqual(roles([adjustments], .image), [])
        XCTAssertEqual(roles([photo], .other), [])
        XCTAssertEqual(roles([photo], .video), [], "a video asset needs a video resource")
        // An app-created edit with no base resource: the rendition only.
        XCTAssertEqual(roles([edited], .image), ["primary=FullSizeRender.jpg"])
    }

    func testKindsAndMime() {
        XCTAssertEqual(ResourceSelection.itemKind(role: .primary, media: .image, isLivePhoto: true), .livePhoto)
        XCTAssertEqual(ResourceSelection.itemKind(role: .primary, media: .image, isLivePhoto: false), .photo)
        XCTAssertEqual(ResourceSelection.itemKind(role: .liveVideo, media: .image, isLivePhoto: true), .video)
        XCTAssertEqual(ResourceSelection.itemKind(role: .original, media: .image, isLivePhoto: true), .photo)
        XCTAssertEqual(ResourceSelection.itemKind(role: .primary, media: .video, isLivePhoto: false), .video)
        XCTAssertEqual(ResourceSelection.mime(uti: "public.heic", filename: "x"), "image/heic")
        XCTAssertEqual(ResourceSelection.mime(uti: "com.apple.quicktime-movie", filename: "x"), "video/quicktime")
        XCTAssertEqual(ResourceSelection.mime(uti: "dyn.unknown", filename: "a.JPG"), "image/jpeg")
        XCTAssertEqual(ResourceSelection.mime(uti: "dyn.unknown", filename: "a.bin"), "application/octet-stream")
    }
}

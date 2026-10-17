// swift-tools-version:6.0
import PackageDescription

// The Pigeon bridge (Sources/PicTunnelEngine/Bridge/Pigeon.g.swift) imports Flutter, which no
// SwiftPM package can resolve, so it is excluded here and compiled by the Runner target instead.
// Its `ItemState`/`PauseReason` mirror the engine's own types by the same names; keeping it out
// of this module avoids the clash, and Runner maps between the two explicitly.
let package = Package(
    name: "PicTunnelEngine",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PicTunnelEngine", targets: ["PicTunnelEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "PicTunnelEngine",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                // CryptoKit on Apple platforms; swift-crypto's `Crypto` only where CryptoKit is absent.
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            exclude: ["Bridge"]
        ),
        .testTarget(name: "PicTunnelEngineTests", dependencies: ["PicTunnelEngine"]),
    ]
)

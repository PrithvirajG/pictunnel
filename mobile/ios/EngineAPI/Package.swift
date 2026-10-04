// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EngineAPI",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "EngineAPI", targets: ["EngineAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "EngineAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "EngineAPITests", dependencies: ["EngineAPI"]),
    ]
)

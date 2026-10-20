// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "elbbepTransport",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ElbbepTransport", targets: ["ElbbepTransport"]),
        .library(name: "LupedKit", targets: ["LupedKit"]),
    ],
    targets: [
        .target(
            name: "ElbbepTransport",
            path: "Sources/ElbbepTransport"
        ),
        .target(
            name: "LupedKit",
            dependencies: ["ElbbepTransport"],
            path: "Sources/LupedKit",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ElbbepTransportTests",
            dependencies: ["ElbbepTransport"],
            path: "Tests/ElbbepTransportTests"
        ),
        .testTarget(
            name: "LupedKitTests",
            dependencies: ["LupedKit"],
            path: "Tests/LupedKitTests"
        ),
    ]
)

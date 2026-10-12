// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "elbbepTransport",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ElbbepTransport", targets: ["ElbbepTransport"]),
    ],
    targets: [
        .target(
            name: "ElbbepTransport",
            path: "Sources/ElbbepTransport"
        ),
        .testTarget(
            name: "ElbbepTransportTests",
            dependencies: ["ElbbepTransport"],
            path: "Tests/ElbbepTransportTests"
        ),
    ]
)

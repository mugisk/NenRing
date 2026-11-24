// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NenRing",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "NenRing", targets: ["NenRing"])
    ],
    targets: [
        .executableTarget(
            name: "NenRing",
            path: "Sources/NenRing",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "NenRingTests",
            dependencies: ["NenRing"],
            path: "Tests/NenRingTests"
        )
    ]
)

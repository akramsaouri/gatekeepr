// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "gatekeepr",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GatekeeprCore", targets: ["GatekeeprCore"]),
        .executable(name: "gatekeepr", targets: ["gatekeepr"]),
    ],
    dependencies: [
        // 1.8 needs Swift 6 tools (Xcode 16), which macOS 13 can't run.
        .package(url: "https://github.com/apple/swift-argument-parser", "1.5.0"..<"1.8.0"),
    ],
    targets: [
        // The system zlib, used to read the rotated driver-*.log.gz files.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "GatekeeprCore",
            dependencies: ["CZlib"]
        ),
        .executableTarget(
            name: "gatekeepr",
            dependencies: [
                "GatekeeprCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Milestone 2: the Gatekeepr.app menu bar target (SwiftUI MenuBarExtra) goes here.
        .testTarget(
            name: "GatekeeprCoreTests",
            dependencies: ["GatekeeprCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

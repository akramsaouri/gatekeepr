// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "gatekeepr",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GatekeeprCore", targets: ["GatekeeprCore"]),
        .executable(name: "gatekeepr", targets: ["gatekeepr"]),
        // The menu bar app's binary. scripts/build-app wraps it in Gatekeepr.app.
        // It isn't called "Gatekeepr" because on a case-insensitive volume that
        // would collide with the gatekeepr CLI in .build/.
        .executable(name: "GatekeeprApp", targets: ["GatekeeprApp"]),
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
        // The menu bar app's logic: state mapping, notification bookkeeping,
        // settings and the log watcher. Kept out of the app target so it can be tested.
        .target(
            name: "GatekeeprMenuBar",
            dependencies: ["GatekeeprCore"]
        ),
        // Gatekeepr.app: the SwiftUI MenuBarExtra and the system glue
        // (notifications, launch at login, opening Appgate).
        .executableTarget(
            name: "GatekeeprApp",
            dependencies: ["GatekeeprCore", "GatekeeprMenuBar"]
        ),
        .testTarget(
            name: "GatekeeprCoreTests",
            dependencies: ["GatekeeprCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "GatekeeprMenuBarTests",
            dependencies: ["GatekeeprCore", "GatekeeprMenuBar"]
        ),
    ]
)

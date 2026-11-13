// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LockedIn",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LockedInCore", targets: ["LockedInCore"]),
        .executable(name: "lockedind", targets: ["lockedind"]),
        .executable(name: "lockedin", targets: ["lockedin"]),
        .executable(name: "LockedInApp", targets: ["LockedInApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0")
    ],
    targets: [
        .target(name: "LockedInCore"),
        .target(name: "LockedInClient", dependencies: ["LockedInCore"]),
        .executableTarget(name: "lockedind", dependencies: ["LockedInCore"]),
        .executableTarget(
            name: "lockedin",
            dependencies: [
                "LockedInCore",
                "LockedInClient",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "LockedInApp",
            dependencies: ["LockedInCore", "LockedInClient"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "LockedInCoreTests", dependencies: ["LockedInCore"]),
        .testTarget(name: "lockedindTests", dependencies: ["lockedind"]),
    ],
    swiftLanguageModes: [.v6]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yuzu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Yuzu", targets: ["Yuzu"]),
        .library(name: "YuzuCore", targets: ["YuzuCore"]),
    ],
    targets: [
        .target(
            name: "YuzuCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Yuzu",
            dependencies: ["YuzuCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "YuzuCoreTests",
            dependencies: ["YuzuCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

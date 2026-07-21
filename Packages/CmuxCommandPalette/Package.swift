// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCommandPalette",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxCommandPalette",
            targets: ["CmuxCommandPalette"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxProcess"),
    ],
    targets: [
        .target(
            name: "CmuxCommandPalette",
            dependencies: ["CmuxProcess"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCommandPaletteTests",
            dependencies: ["CmuxCommandPalette", "CmuxProcess"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)

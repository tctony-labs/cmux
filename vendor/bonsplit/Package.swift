// swift-tools-version: 5.9

// Vendored from manaflow-ai/bonsplit at ddb46fe94fbbd1efd062d80371ca2455c4296eb5.
// Local fixes are maintained directly in the cmux repository.

import PackageDescription

let package = Package(
    name: "Bonsplit",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "Bonsplit",
            targets: ["Bonsplit"]
        ),
    ],
    targets: [
        .target(
            name: "Bonsplit",
            dependencies: [],
            path: "Sources/Bonsplit",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "BonsplitTests",
            dependencies: ["Bonsplit"],
            path: "Tests/BonsplitTests"
        ),
    ]
)

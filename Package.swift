// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "watchthrough",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "watchthrough", targets: ["WatchthroughCLI"]),
    ],
    targets: [
        .target(name: "WatchthroughCore", path: "Sources/WatchthroughCore"),
        .executableTarget(
            name: "WatchthroughCLI",
            dependencies: ["WatchthroughCore"],
            path: "Sources/WatchthroughCLI"
        ),
        .testTarget(
            name: "WatchthroughCoreTests",
            dependencies: ["WatchthroughCore"],
            path: "Tests/WatchthroughCoreTests"
        ),
    ]
)

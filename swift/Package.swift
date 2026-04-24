// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "fend",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "fend", targets: ["FendCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "FendCLI",
            dependencies: [
                "FendCommon",
                "FendDaemon",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "FendDaemon",
            dependencies: [
                "FendCommon",
            ]
        ),
        .target(
            name: "FendCommon"
        ),
        .testTarget(
            name: "FendCommonTests",
            dependencies: ["FendCommon"]
        ),
        .testTarget(
            name: "FendDaemonTests",
            dependencies: ["FendDaemon"]
        ),
        .testTarget(
            name: "FendCLITests",
            dependencies: ["FendCommon", "FendCLI"]
        ),
    ]
)

// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RsyncProcess",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "RsyncProcess",
            targets: ["RsyncProcess"]
        )
    ],
    targets: [
        .target(
            name: "RsyncProcess",
            dependencies: []
        ),
        .testTarget(
            name: "RsyncProcessTests",
            dependencies: ["RsyncProcess"]
        )
    ]
)

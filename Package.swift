// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RsyncProcess",
    platforms: [
        .macOS(.v14)
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
/*
let strictConcurrencyTargets = ["RsyncUI"]

for target in package.targets where strictConcurrencyTargets.contains(target.name) {
  var settings = target.swiftSettings ?? []
  settings.append(contentsOf: [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances")
  ])
  target.swiftSettings = settings
}
*/

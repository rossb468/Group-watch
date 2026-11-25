// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GroupWatchCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GroupWatchCore", targets: ["GroupWatchCore"]),
    ],
    targets: [
        .target(name: "GroupWatchCore"),
        .testTarget(name: "GroupWatchCoreTests", dependencies: ["GroupWatchCore"]),
    ]
)

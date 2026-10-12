// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LPCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LPCore", targets: ["LPCore"])],
    targets: [
        .target(name: "LPCore"),
        .testTarget(name: "LPCoreTests", dependencies: ["LPCore"]),
    ]
)

// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "swift-convex-consumer",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/markmals/swift-convex.git", from: "0.0.0")
    ],
    targets: [
        .testTarget(
            name: "ConsumerTests",
            dependencies: [.product(name: "Convex", package: "swift-convex")],
            exclude: ["convex-swift.json"],
            plugins: [.plugin(name: "ConvexGenerate", package: "swift-convex")]
        )
    ],
    swiftLanguageModes: [.v6]
)

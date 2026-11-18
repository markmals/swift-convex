// swift-tools-version: 6.4

import Foundation
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let nativeRuntime: Target
if ProcessInfo.processInfo.environment["CONVEX_NATIVE_LOCAL"] == "1" {
    nativeRuntime = .binaryTarget(
        name: "ConvexRuntimeFFI",
        path: ".build/native/ConvexRuntimeFFI.xcframework"
    )
} else {
    nativeRuntime = .binaryTarget(
        name: "ConvexRuntimeFFI",
        url: "https://api.github.com/repos/markmals/swift-convex/releases/assets/761266205.zip",
        checksum: "77edb2930791f0f4b8cfa447dc96174f83b43ab16993c6fd3ade5266af30de60"
    )
}

let package = Package(
    name: "swift-convex",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Convex", targets: ["Convex"]),
        .executable(name: "convex-swift-codegen", targets: ["convex-swift-codegen"]),
        .plugin(name: "ConvexGenerate", targets: ["ConvexGenerate"]),
        .plugin(name: "GenerateConvex", targets: ["GenerateConvex"]),
    ],
    targets: [
        nativeRuntime,
        .target(name: "ConvexNativeBindings", dependencies: ["ConvexRuntimeFFI"]),
        .target(
            name: "ConvexNative",
            dependencies: ["ConvexNativeBindings"],
            swiftSettings: swiftSettings
        ),
        .target(name: "Convex", dependencies: ["ConvexNative"], swiftSettings: swiftSettings),
        .target(name: "ConvexContract", swiftSettings: swiftSettings),
        .target(
            name: "ConvexCodegen",
            dependencies: ["ConvexContract"],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "convex-swift-codegen",
            dependencies: ["ConvexCodegen"],
            path: "Sources/ConvexCodegenCLI",
            swiftSettings: swiftSettings
        ),
        .plugin(
            name: "ConvexGenerate",
            capability: .buildTool(),
            dependencies: ["convex-swift-codegen"]
        ),
        .plugin(
            name: "GenerateConvex",
            capability: .command(
                intent: .custom(
                    verb: "generate-convex",
                    description: "Generate Swift requests from a local Convex contract"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Write the configured generated Swift source")
                ]
            ),
            dependencies: ["convex-swift-codegen"]
        ),
        .testTarget(name: "ConvexTests", dependencies: ["Convex"], swiftSettings: swiftSettings),
        .testTarget(
            name: "ConvexNativeTests",
            dependencies: ["ConvexNative"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ConvexIntegrationTests",
            dependencies: ["Convex"],
            exclude: ["convex-swift.json"],
            swiftSettings: swiftSettings,
            plugins: [.plugin(name: "ConvexGenerate")]
        ),
        .testTarget(
            name: "ConvexCodegenTests",
            dependencies: ["ConvexCodegen", "ConvexContract"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)

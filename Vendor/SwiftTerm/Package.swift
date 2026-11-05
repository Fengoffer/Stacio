// swift-tools-version: 5.9

import PackageDescription

#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = []
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"])
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: platformExcludes + ["Mac/README.md"],
            resources: [
                .process("Apple/Metal/Shaders.metal")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)

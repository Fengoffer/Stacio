// swift-tools-version: 5.10
import Foundation
import PackageDescription

let stacioCoreLibraryDirectory = ProcessInfo.processInfo.environment["STACIO_CORE_LIBRARY_DIR"] ?? "StacioCore/target/debug"

let package = Package(
    name: "Stacio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Stacio", targets: ["StacioExecutable"]),
        .executable(name: "StacioVNCAdapter", targets: ["StacioVNCAdapter"]),
        .executable(name: "StacioCLI", targets: ["StacioCLI"]),
        .library(name: "StacioAgentBridge", targets: ["StacioAgentBridge"]),
        .library(name: "StacioApp", targets: ["StacioApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", .upToNextMajor(from: "2.7.0")),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", .upToNextMajor(from: "1.13.0"))
    ],
    targets: [
        .target(
            name: "StacioAgentBridge",
            path: "StacioAgentBridge"
        ),
        .executableTarget(
            name: "StacioCLI",
            dependencies: ["StacioAgentBridge"],
            path: "StacioCLI"
        ),
        .target(
            name: "StacioCoreBindings",
            dependencies: ["stacio_coreFFI"],
            path: "Stacio/Bridge/Generated/Sources",
            linkerSettings: [
                .unsafeFlags(["-L", stacioCoreLibraryDirectory, "-lstacio_core"])
            ]
        ),
        .systemLibrary(
            name: "stacio_coreFFI",
            path: "Stacio/Bridge/Generated/Headers"
        ),
        .target(
            name: "StacioApp",
            dependencies: [
                "StacioAgentBridge",
                "StacioCoreBindings",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Stacio",
            exclude: [
                "Bridge/Generated",
                "Resources/AppIcon"
            ],
            resources: [
                .process("Resources/About"),
                .process("Resources/github.svg"),
                .process("Resources/gitee.svg"),
                .process("Resources/SessionIcons"),
                .process("Resources/ImportSourceIcons")
            ]
        ),
        .executableTarget(
            name: "StacioExecutable",
            dependencies: ["StacioApp"],
            path: "StacioExecutable"
        ),
        .executableTarget(
            name: "StacioVNCAdapter",
            path: "StacioAdapters/VNC"
        ),
        .testTarget(
            name: "StacioAppTests",
            dependencies: [
                "StacioAgentBridge",
                "StacioApp",
                "StacioCoreBindings",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Tests/StacioAppTests"
        ),
        .testTarget(
            name: "StacioAgentBridgeTests",
            dependencies: ["StacioAgentBridge"],
            path: "Tests/StacioAgentBridgeTests"
        )
    ]
)

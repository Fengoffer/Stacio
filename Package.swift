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
        .package(path: "Vendor/SwiftTerm"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
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
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Stacio",
            exclude: [
                "Bridge/Generated",
                "Resources/AppIcon",
                // Oh My Zsh is a separately verified, on-demand download.
                // Keep the vendored source for release snapshot generation, but
                // never include the full snapshot in the application bundle.
                "Resources/OhMyZsh",
                // Nerd Font 同样走 oh-my-zsh 快照按需下载，不内置进 app。
                // 源码文件保留给 scripts/sync-ohmyzsh-resources.sh 生成快照。
                "Resources/Fonts/JetBrainsMonoNLNerdFont-Regular.ttf",
                "Resources/Fonts/NerdFonts-OFL.txt"
            ],
            resources: [
                .process("Resources/About"),
                .copy("Resources/LicenseCertificate"),
                .process("Resources/github.svg"),
                .process("Resources/gitee.svg"),
                .process("Resources/SessionIcons"),
                .process("Resources/ImportSourceIcons"),
                .process("Resources/RuntimeCatalog"),
                .copy("Resources/Fonts/SarasaTermSC-Regular.ttf"),
                .copy("Resources/Fonts/SarasaTermSC-Bold.ttf"),
                .copy("Resources/Fonts/LICENSE.txt"),
                .copy("Resources/Fonts/lack-regular-2.otf"),
                .copy("Resources/stacio-logo.png")
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreBluetooth")
            ]
        ),
        .executableTarget(
            name: "StacioExecutable",
            dependencies: ["StacioApp"],
            path: "StacioExecutable"
        ),
        .target(
            name: "StacioVNCAdapterCore",
            path: "StacioAdapters/VNCCore"
        ),
        .executableTarget(
            name: "StacioVNCAdapter",
            dependencies: ["StacioVNCAdapterCore"],
            path: "StacioAdapters/VNC"
        ),
        .testTarget(
            name: "StacioAppTests",
            dependencies: [
                "StacioAgentBridge",
                "StacioApp",
                "StacioCoreBindings",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Tests/StacioAppTests"
        ),
        .testTarget(
            name: "StacioAgentBridgeTests",
            dependencies: ["StacioAgentBridge"],
            path: "Tests/StacioAgentBridgeTests"
        ),
        .testTarget(
            name: "StacioVNCAdapterCoreTests",
            dependencies: ["StacioVNCAdapterCore"],
            path: "Tests/StacioVNCAdapterCoreTests"
        ),
        .testTarget(
            name: "StacioOhMyZshAcceptance",
            dependencies: [
                "StacioApp",
                "StacioCoreBindings",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Tests/StacioOhMyZshAcceptance"
        )
    ]
)

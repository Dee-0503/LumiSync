// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumiSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LumiSyncCore", targets: ["LumiSyncCore"]),
        .library(name: "LumiSyncAppSupport", targets: ["LumiSyncAppSupport"]),
        .executable(name: "lumisync", targets: ["LumiSyncCLI"]),
        .executable(name: "LumiSyncApp", targets: ["LumiSyncApp"])
    ],
    targets: [
        .target(name: "LumiSyncCore"),
        .target(
            name: "LumiSyncAppSupport",
            dependencies: ["LumiSyncCore"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(name: "LumiSyncCLI", dependencies: ["LumiSyncCore"]),
        .executableTarget(
            name: "LumiSyncApp",
            dependencies: ["LumiSyncCore", "LumiSyncAppSupport"],
            path: "Apps/LumiSyncApp",
            exclude: ["README.md"]
        ),
        .testTarget(name: "LumiSyncCoreTests", dependencies: ["LumiSyncCore"]),
        .testTarget(
            name: "LumiSyncAppSupportTests",
            dependencies: ["LumiSyncAppSupport", "LumiSyncCore"]
        )
    ]
)

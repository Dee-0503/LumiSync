// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumiSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LumiSyncCore", targets: ["LumiSyncCore"]),
        .library(name: "LumiSyncAppSupport", targets: ["LumiSyncAppSupport"]),
        .library(name: "LumiSyncKeyboardProbe", targets: ["LumiSyncKeyboardProbe"]),
        .executable(name: "lumisync", targets: ["LumiSyncCLI"]),
        .executable(name: "LumiSyncApp", targets: ["LumiSyncApp"]),
        .executable(name: "lumisync-keyboard-probe", targets: ["LumiSyncKeyboardProbeCLI"])
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
        .target(name: "LumiSyncKeyboardProbe"),
        .executableTarget(name: "LumiSyncCLI", dependencies: ["LumiSyncCore"]),
        .executableTarget(
            name: "LumiSyncApp",
            dependencies: ["LumiSyncCore", "LumiSyncAppSupport"],
            path: "Apps/LumiSyncApp",
            exclude: ["README.md"]
        ),
        .executableTarget(name: "LumiSyncKeyboardProbeCLI", dependencies: ["LumiSyncKeyboardProbe"]),
        .testTarget(name: "LumiSyncCoreTests", dependencies: ["LumiSyncCore"]),
        .testTarget(
            name: "LumiSyncAppSupportTests",
            dependencies: ["LumiSyncAppSupport", "LumiSyncCore"]
        ),
        .testTarget(name: "LumiSyncKeyboardProbeTests", dependencies: ["LumiSyncKeyboardProbe"])
    ]
)

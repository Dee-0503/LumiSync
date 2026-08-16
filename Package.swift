// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumiSync",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LumiSyncCore", targets: ["LumiSyncCore"]),
        .library(name: "LumiSyncAppSupport", targets: ["LumiSyncAppSupport"]),
        .library(name: "LumiSyncKeyboardProbe", targets: ["LumiSyncKeyboardProbe"]),
        .executable(name: "lumisync", targets: ["LumiSyncCLI"]),
        .executable(name: "LumiSyncApp", targets: ["LumiSyncApp"]),
        .executable(name: "lumisync-keyboard-probe", targets: ["LumiSyncKeyboardProbeCLI"]),
        .executable(name: "lumisync-backlight-writer", targets: ["LumiSyncBacklightWriterCLI"]),
        .executable(name: "lumisync-backlight-supervisor", targets: ["LumiSyncBacklightSupervisorCLI"]),
        .executable(name: "lumisync-backlight-controller", targets: ["LumiSyncBacklightControllerCLI"])
    ],
    targets: [
        .target(name: "LumiSyncCore"),
        .target(
            name: "LumiSyncAppSupport",
            dependencies: ["LumiSyncCore"],
            resources: [.process("Resources")],
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
        .executableTarget(name: "LumiSyncBacklightWriterCLI", dependencies: ["LumiSyncKeyboardProbe"]),
        .executableTarget(name: "LumiSyncBacklightSupervisorCLI", dependencies: ["LumiSyncKeyboardProbe"]),
        .executableTarget(name: "LumiSyncBacklightControllerCLI", dependencies: ["LumiSyncKeyboardProbe"]),
        .testTarget(name: "LumiSyncCoreTests", dependencies: ["LumiSyncCore"]),
        .testTarget(
            name: "LumiSyncAppSupportTests",
            dependencies: ["LumiSyncAppSupport", "LumiSyncCore"]
        ),
        .testTarget(name: "LumiSyncKeyboardProbeTests", dependencies: ["LumiSyncKeyboardProbe"])
    ]
)

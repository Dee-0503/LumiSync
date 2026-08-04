// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumiSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LumiSyncCore", targets: ["LumiSyncCore"]),
        .executable(name: "lumisync", targets: ["LumiSyncCLI"])
    ],
    targets: [
        .target(name: "LumiSyncCore"),
        .executableTarget(name: "LumiSyncCLI", dependencies: ["LumiSyncCore"]),
        .testTarget(name: "LumiSyncCoreTests", dependencies: ["LumiSyncCore"])
    ]
)

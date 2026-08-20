import Foundation
import XCTest

final class ReleaseBundleFixtureTests: XCTestCase {
    private struct ManifestEntry {
        let path: String
        let product: String
        let role: String
    }
    func testBuilderProducesVerifiedUnsignedBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseBundleBuilder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let buildDirectory = root.appendingPathComponent("build", isDirectory: true)
        let app = buildDirectory.appendingPathComponent("unsigned-release/LumiSync.app", isDirectory: true)
        let result = try runBuilder(
            buildDirectory: buildDirectory,
            version: "0.2.0-dev",
            buildNumber: "2"
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path), result.output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/LumiSync").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Helpers/lumisync-backlight-controller").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Helpers/lumisync-backlight-supervisor").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Helpers/lumisync-backlight-writer").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_CodeSignature").path))

        let verification = try runVerifier(
            app: app,
            manifest: repositoryRoot.appendingPathComponent("Packaging/LumiSync/NestedCode.json"),
            allowMockMachO: false,
            version: "0.2.0-dev",
            buildNumber: "2"
        )
        XCTAssertEqual(verification.status, 0, verification.output)
        XCTAssertTrue(verification.output.contains("Verified unsigned release bundle"), verification.output)
    }

    func testAcceptsValidFixtureWithExplicitMockMachOMode() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Verified unsigned release bundle"))
    }

    func testRejectsMockMachOMarkersWithoutFixtureMode() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest, allowMockMachO: false)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("expected Mach-O executable: Contents/MacOS/LumiSync"), result.output)
    }

    func testReportsEachIndependentBundleViolation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("missing expected executable: Contents/Helpers/lumisync-backlight-writer"))
        XCTAssertTrue(result.output.contains("unexpected executable: Contents/Helpers/unexpected-helper"))
        XCTAssertTrue(result.output.contains("CFBundleShortVersionString must be 1.2.3, found 9.9.9"))
        XCTAssertTrue(result.output.contains("forbidden dependency or rpath string '.build'"))
    }

    func testRejectsBundleExecutableThatDoesNotMatchAppRole() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try updateInfoPlist(at: fixture.app) { plist in
            plist["CFBundleExecutable"] = "NotLumiSync"
        }

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains("app executable must match CFBundleExecutable: Contents/MacOS/NotLumiSync"),
            result.output
        )
    }

    func testRejectsAbsoluteIconFilePath() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let externalIcon = fixture.root.appendingPathComponent("External.icns")
        try Data().write(to: externalIcon)
        try updateInfoPlist(at: fixture.app) { plist in
            plist["CFBundleIconFile"] = externalIcon.path
        }

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("CFBundleIconFile must be a relative resource name"), result.output)
    }

    func testRejectsIconSymlinkThatEscapesResources() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let externalIcon = fixture.root.appendingPathComponent("External.icns")
        try Data().write(to: externalIcon)
        let icon = fixture.app.appendingPathComponent("Contents/Resources/LumiSync.icns")
        try FileManager.default.removeItem(at: icon)
        try FileManager.default.createSymbolicLink(at: icon, withDestinationURL: externalIcon)

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains("icon resource must be a regular non-symlink file: Contents/Resources/LumiSync.icns"),
            result.output
        )
    }

    func testRejectsUnexpectedNonExecutableFileInCodeDirectories() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let unexpected = fixture.app.appendingPathComponent("Contents/Helpers/unexpected-data")
        try "not code\n".write(to: unexpected, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unexpected.path)

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("unexpected executable: Contents/Helpers/unexpected-data"), result.output)
    }

    func testRejectsWritableCodeDirectory() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let helpers = fixture.app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: helpers.path)

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("group/world-writable code path: Contents/Helpers"), result.output)
    }

    func testRejectsWritableUnexpectedCodeFile() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let unexpected = fixture.app.appendingPathComponent("Contents/Helpers/unexpected-data")
        try "not code\n".write(to: unexpected, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: unexpected.path)

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("group/world-writable code path: Contents/Helpers/unexpected-data"), result.output)
    }

    func testRejectsStrictManifestViolations() throws {
        for scenario in manifestScenarios {
            let fixture = try makeFixture(manifest: scenario.manifest)
            defer { try? FileManager.default.removeItem(at: fixture.root) }

            let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

            XCTAssertNotEqual(result.status, 0, scenario.name)
            XCTAssertTrue(result.output.contains(scenario.expectedError), "\(scenario.name): \(result.output)")
        }
    }

    func testRejectsSymlinkAndWritableExecutableLocations() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let appExecutable = fixture.app.appendingPathComponent("Contents/MacOS/LumiSync")
        try FileManager.default.removeItem(at: appExecutable)
        try FileManager.default.createSymbolicLink(
            at: appExecutable,
            withDestinationURL: fixture.app.appendingPathComponent("Contents/Helpers/lumisync-backlight-controller")
        )
        let writableHelper = fixture.app.appendingPathComponent("Contents/Helpers/lumisync-backlight-supervisor")
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: writableHelper.path)

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("expected executable must not be a symlink: Contents/MacOS/LumiSync"))
        XCTAssertTrue(result.output.contains("group/world-writable executable: Contents/Helpers/lumisync-backlight-supervisor"))
    }

    func testRejectsSymlinkedExecutableDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let helpers = fixture.app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let relocatedHelpers = fixture.root.appendingPathComponent("RelocatedHelpers", isDirectory: true)
        try FileManager.default.moveItem(at: helpers, to: relocatedHelpers)
        try FileManager.default.createSymbolicLink(at: helpers, withDestinationURL: relocatedHelpers)

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains("expected executable path must not contain a symlink: Contents/Helpers/lumisync-backlight-controller"),
            result.output
        )
    }

    func testRejectsUnexpectedNestedExecutableAndSymlink() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let nested = fixture.app.appendingPathComponent("Contents/Helpers/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedExecutable = nested.appendingPathComponent("nested-helper")
        try writeExecutable(at: nestedExecutable)
        let nestedSymlink = nested.appendingPathComponent("nested-link")
        try FileManager.default.createSymbolicLink(
            at: nestedSymlink,
            withDestinationURL: fixture.app.appendingPathComponent("Contents/Helpers/lumisync-backlight-controller")
        )

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("unexpected executable: Contents/Helpers/Nested/nested-helper"), result.output)
        XCTAssertTrue(result.output.contains("unexpected symlink in code path: Contents/Helpers/Nested/nested-link"), result.output)
    }

    func testRejectsMalformedRealMachOWhenOtoolFails() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let executable = fixture.app.appendingPathComponent("Contents/MacOS/LumiSync")
        let source = try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        try source.prefix(128).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("otool failed for Contents/MacOS/LumiSync"), result.output)
    }

    func testRejectsArm64eMachOArchitecture() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let executable = fixture.app.appendingPathComponent("Contents/MacOS/LumiSync")
        try runTool(
            "/usr/bin/lipo",
            arguments: ["-thin", "arm64e", "/usr/bin/true", "-output", executable.path]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Mach-O architecture must be arm64: Contents/MacOS/LumiSync"), result.output)
    }

    func testAcceptsDeclaredMachOObjectsNestedInAllSupportedBundleLocations() throws {
        let nestedEntries = [
            ManifestEntry(path: "Contents/Frameworks/Lumi.framework/Versions/A/Lumi", product: "LumiFramework", role: "framework"),
            ManifestEntry(path: "Contents/PlugIns/Lumi.appex/Contents/MacOS/LumiExtension", product: "LumiExtension", role: "appex"),
            ManifestEntry(path: "Contents/XPCServices/Lumi.xpc/Contents/MacOS/LumiXPC", product: "LumiXPC", role: "xpc"),
            ManifestEntry(path: "Contents/Resources/Lumi.bundle/Contents/MacOS/LumiBundle", product: "LumiBundle", role: "bundle")
        ]
        let fixture = try makeValidFixture(manifest: manifestJSON(entries: validEntries + nestedEntries))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for path in nestedEntries.map(\.path) {
            let executable = fixture.app.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeExecutable(at: executable)
        }

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertEqual(result.status, 0, result.output)
    }

    func testRejectsUndeclaredMachOObjectNestedInPlugin() throws {
        let fixture = try makeValidFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let executable = fixture.app.appendingPathComponent("Contents/PlugIns/Lumi.appex/Contents/MacOS/LumiExtension")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(at: executable)

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("undeclared Mach-O object: Contents/PlugIns/Lumi.appex/Contents/MacOS/LumiExtension"), result.output)
    }

    func testRejectsManifestThatOmitsRequiredHelpers() throws {
        let manifest = manifestJSON(entries: [
            ManifestEntry(path: "Contents/MacOS/LumiSync", product: "LumiSyncApp", role: "app")
        ])
        let fixture = try makeValidFixture(manifest: manifest)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let helpers = fixture.app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        for helper in [
            "lumisync-backlight-controller",
            "lumisync-backlight-supervisor",
            "lumisync-backlight-writer"
        ] {
            try FileManager.default.removeItem(at: helpers.appendingPathComponent(helper))
        }

        let result = try runVerifier(app: fixture.app, manifest: fixture.manifest)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("missing required executable roles: controller, supervisor, writer"), result.output)
    }

    func testBuilderRejectsManifestThatOmitsRequiredHelpers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MissingRequiredBuilder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = root.appendingPathComponent("NestedCode.json")
        try manifestJSON(entries: [
            ManifestEntry(path: "Contents/MacOS/LumiSync", product: "LumiSyncApp", role: "app")
        ]).write(to: manifest, atomically: true, encoding: .utf8)

        let result = try runBuilder(
            buildDirectory: root.appendingPathComponent("build", isDirectory: true),
            version: "0.2.0-dev",
            buildNumber: "2",
            manifest: manifest
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("missing required executable roles: controller, supervisor, writer"), result.output)
    }

    func testBuilderRejectsNoncanonicalRequiredExecutablePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoncanonicalRequiredBuilder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = root.appendingPathComponent("NestedCode.json")
        let relocatedController = "Contents/Helpers/Derived/lumisync-backlight-controller"
        let entries = validEntries.map { entry in
            entry.role == "controller"
                ? ManifestEntry(path: relocatedController, product: entry.product, role: entry.role)
                : entry
        }
        try manifestJSON(entries: entries).write(to: manifest, atomically: true, encoding: .utf8)

        let buildDirectory = root.appendingPathComponent("build", isDirectory: true)
        let result = try runBuilder(
            buildDirectory: buildDirectory,
            version: "0.2.0-dev",
            buildNumber: "2",
            manifest: manifest
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.output.contains("required executable role controller must use path Contents/Helpers/lumisync-backlight-controller"),
            result.output
        )
        let app = buildDirectory.appendingPathComponent("unsigned-release/LumiSync.app", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent(relocatedController).path))
    }

    func testBuilderRejectsTraversalDestinationBeforeWritingOutsideStaging() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TraversalDestinationBuilder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let escapedName = "escaped-\(UUID().uuidString)"
        let traversalPath = "Contents/../../../../../../../../../../../../tmp/\(escapedName)"
        let manifest = root.appendingPathComponent("NestedCode.json")
        let entries = validEntries + [
            ManifestEntry(path: traversalPath, product: "LumiSyncApp", role: "extra")
        ]
        try manifestJSON(entries: entries).write(to: manifest, atomically: true, encoding: .utf8)
        let escaped = URL(fileURLWithPath: "/tmp").appendingPathComponent(escapedName)
        try? FileManager.default.removeItem(at: escaped)
        defer { try? FileManager.default.removeItem(at: escaped) }

        let result = try runBuilder(
            buildDirectory: root.appendingPathComponent("build", isDirectory: true),
            version: "0.2.0-dev",
            buildNumber: "2",
            manifest: manifest
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("executable path must not contain traversal"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path), result.output)
    }

    private var manifestScenarios: [(name: String, manifest: String, expectedError: String)] {
        [
            (
                "duplicate path",
                manifestJSON(entries: [
                    entry("Contents/MacOS/LumiSync", "LumiSyncApp", "app"),
                    entry("Contents/MacOS/LumiSync", "other", "controller")
                ]),
                "duplicate executable path: Contents/MacOS/LumiSync"
            ),
            (
                "duplicate role",
                manifestJSON(entries: [
                    entry("Contents/MacOS/LumiSync", "LumiSyncApp", "app"),
                    entry("Contents/Helpers/other", "other", "app")
                ]),
                "duplicate executable role: app"
            ),
            (
                "absolute path",
                manifestJSON(entries: [entry("/tmp/LumiSync", "LumiSyncApp", "app")]),
                "executable path must be relative: /tmp/LumiSync"
            ),
            (
                "path traversal",
                manifestJSON(entries: [entry("Contents/Helpers/../writer", "writer", "writer")]),
                "executable path must not contain traversal: Contents/Helpers/../writer"
            ),
            (
                "empty path component",
                manifestJSON(entries: [entry("Contents//MacOS/LumiSync", "LumiSyncApp", "app")]),
                "executable path must use canonical relative syntax: Contents//MacOS/LumiSync"
            ),
            (
                "backslash separator",
                manifestJSON(entries: [entry(#"Contents\\Helpers\\writer"#, "writer", "writer")]),
                #"executable path must use canonical relative syntax: Contents\Helpers\writer"#
            )
        ]
    }

    private func makeValidFixture(manifest: String? = nil) throws -> (root: URL, app: URL, manifest: URL) {
        let fixture = try makeFixture(manifest: manifest)
        let helpers = fixture.app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.removeItem(at: helpers.appendingPathComponent("unexpected-helper"))
        try writeExecutable(at: helpers.appendingPathComponent("lumisync-backlight-writer"))

        let plist: [String: Any] = [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "LumiSync",
            "CFBundleIconFile": "LumiSync.icns"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: fixture.app.appendingPathComponent("Contents/Info.plist"))
        try "MOCK_MACHO_ARCH=arm64\n".write(
            to: fixture.app.appendingPathComponent("Contents/MacOS/LumiSync"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.app.appendingPathComponent("Contents/MacOS/LumiSync").path
        )
        return fixture
    }

    private func makeFixture(manifest: String? = nil) throws -> (root: URL, app: URL, manifest: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReleaseBundleFixture-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("LumiSync.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let helpers = contents.appendingPathComponent("Helpers", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let localizationBundle = resources.appendingPathComponent("LumiSync_LumiSyncAppSupport.bundle", isDirectory: true)
        let manifestURL = root.appendingPathComponent("NestedCode.json")

        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localizationBundle, withIntermediateDirectories: true)
        try Data().write(to: resources.appendingPathComponent("LumiSync.icns"))
        try writeExecutable(
            at: macOS.appendingPathComponent("LumiSync"),
            marker: "MOCK_MACHO_ARCH=arm64\nMOCK_DEPENDENCY=/tmp/repo/.build/release/library.dylib\n"
        )
        try writeExecutable(at: helpers.appendingPathComponent("lumisync-backlight-controller"))
        try writeExecutable(at: helpers.appendingPathComponent("lumisync-backlight-supervisor"))
        try writeExecutable(at: helpers.appendingPathComponent("unexpected-helper"))

        let plist: [String: Any] = [
            "CFBundleShortVersionString": "9.9.9",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "LumiSync",
            "CFBundleIconFile": "LumiSync.icns"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        try (manifest ?? validManifest).write(to: manifestURL, atomically: true, encoding: .utf8)

        return (root, app, manifestURL)
    }

    private func updateInfoPlist(at app: URL, update: (inout [String: Any]) -> Void) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: plistURL),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        update(&plist)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL)
    }

    private func writeExecutable(at url: URL, marker: String = "MOCK_MACHO_ARCH=arm64\n") throws {
        try marker.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runBuilder(
        buildDirectory: URL,
        version: String,
        buildNumber: String,
        manifest: URL? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRoot.appendingPathComponent("Scripts/build-unsigned-release-app.sh").path
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "BUILD_DIR": buildDirectory.path,
            "VERSION": version,
            "BUILD_NUMBER": buildNumber,
            "CONFIGURATION": "release"
        ].merging(manifest.map { ["NESTED_CODE_MANIFEST": $0.path] } ?? [:]) { _, override in override }) { _, override in override }
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func runVerifier(
        app: URL,
        manifest: URL,
        allowMockMachO: Bool = true,
        version: String = "1.2.3",
        buildNumber: String = "42"
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            repositoryRoot.appendingPathComponent("Scripts/verify-release-bundle.py").path,
            "--app", app.path,
            "--manifest", manifest.path,
            "--version", version,
            "--build-number", buildNumber
        ] + (allowMockMachO ? ["--allow-mock-macho"] : [])
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func runTool(_ executablePath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executablePath) failed")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var validEntries: [ManifestEntry] {
        [
            ManifestEntry(path: "Contents/MacOS/LumiSync", product: "LumiSyncApp", role: "app"),
            ManifestEntry(path: "Contents/Helpers/lumisync-backlight-controller", product: "lumisync-backlight-controller", role: "controller"),
            ManifestEntry(path: "Contents/Helpers/lumisync-backlight-supervisor", product: "lumisync-backlight-supervisor", role: "supervisor"),
            ManifestEntry(path: "Contents/Helpers/lumisync-backlight-writer", product: "lumisync-backlight-writer", role: "writer")
        ]
    }

    private var validManifest: String {
        manifestJSON(entries: validEntries)
    }

    private func entry(_ path: String, _ product: String, _ role: String) -> String {
        "{\"path\":\"\(path)\",\"product\":\"\(product)\",\"role\":\"\(role)\"}"
    }

    private func manifestJSON(entries: [ManifestEntry]) -> String {
        manifestJSON(entries: entries.map { entry($0.path, $0.product, $0.role) })
    }

    private func manifestJSON(entries: [String]) -> String {
        "{\"version\":1,\"executables\":[\(entries.joined(separator: ","))]}"
    }
}

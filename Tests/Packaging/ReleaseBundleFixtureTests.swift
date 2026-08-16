import Foundation
import XCTest

final class ReleaseBundleFixtureTests: XCTestCase {
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

    private func makeValidFixture() throws -> (root: URL, app: URL, manifest: URL) {
        let fixture = try makeFixture()
        let helpers = fixture.app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.removeItem(at: helpers.appendingPathComponent("unexpected-helper"))
        try writeExecutable(at: helpers.appendingPathComponent("lumisync-backlight-writer"))

        let plist: [String: Any] = [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
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
            "CFBundleIconFile": "LumiSync.icns"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        try (manifest ?? validManifest).write(to: manifestURL, atomically: true, encoding: .utf8)

        return (root, app, manifestURL)
    }

    private func writeExecutable(at url: URL, marker: String = "MOCK_MACHO_ARCH=arm64\n") throws {
        try marker.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runVerifier(
        app: URL,
        manifest: URL,
        allowMockMachO: Bool = true
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            repositoryRoot.appendingPathComponent("Scripts/verify-release-bundle.py").path,
            "--app", app.path,
            "--manifest", manifest.path,
            "--version", "1.2.3",
            "--build-number", "42"
        ] + (allowMockMachO ? ["--allow-mock-macho"] : [])
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var validManifest: String {
        manifestJSON(entries: [
            entry("Contents/MacOS/LumiSync", "LumiSyncApp", "app"),
            entry("Contents/Helpers/lumisync-backlight-controller", "lumisync-backlight-controller", "controller"),
            entry("Contents/Helpers/lumisync-backlight-supervisor", "lumisync-backlight-supervisor", "supervisor"),
            entry("Contents/Helpers/lumisync-backlight-writer", "lumisync-backlight-writer", "writer")
        ])
    }

    private func entry(_ path: String, _ product: String, _ role: String) -> String {
        "{\"path\":\"\(path)\",\"product\":\"\(product)\",\"role\":\"\(role)\"}"
    }

    private func manifestJSON(entries: [String]) -> String {
        "{\"version\":1,\"executables\":[\(entries.joined(separator: ","))]}"
    }
}

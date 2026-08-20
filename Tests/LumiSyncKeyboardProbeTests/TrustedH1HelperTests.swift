import Darwin
import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class TrustedH1HelperTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testResolverAcceptsFixedExecutableSibling() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeExecutable(named: "lumisync-backlight-controller", in: directory)
        let supervisor = try makeExecutable(named: "lumisync-backlight-supervisor", in: directory)

        XCTAssertEqual(
            try TrustedH1Helper.resolve(.supervisor, relativeTo: controller),
            supervisor
        )
    }

    func testResolverRejectsMissingSibling() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeExecutable(named: "lumisync-backlight-controller", in: directory)

        XCTAssertThrowsError(
            try TrustedH1Helper.resolve(.supervisor, relativeTo: controller)
        )
    }

    func testResolverRejectsSymlinkSibling() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeExecutable(named: "lumisync-backlight-controller", in: directory)
        let target = try makeExecutable(named: "target", in: directory)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("lumisync-backlight-supervisor"),
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try TrustedH1Helper.resolve(.supervisor, relativeTo: controller)
        )
    }

    func testResolverRejectsGroupWritableSibling() throws {
        let directory = try makeTemporaryDirectory()
        let controller = try makeExecutable(named: "lumisync-backlight-controller", in: directory)
        _ = try makeExecutable(
            named: "lumisync-backlight-supervisor",
            in: directory,
            mode: 0o775
        )

        XCTAssertThrowsError(
            try TrustedH1Helper.resolve(.supervisor, relativeTo: controller)
        )
    }

    func testResolverRejectsSymlinkParentDirectory() throws {
        let directory = try makeTemporaryDirectory()
        let realDirectory = directory.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        _ = try makeExecutable(named: "lumisync-backlight-controller", in: realDirectory)
        _ = try makeExecutable(named: "lumisync-backlight-supervisor", in: realDirectory)
        let linkedDirectory = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )
        let linkedController = linkedDirectory.appendingPathComponent("lumisync-backlight-controller")

        XCTAssertThrowsError(
            try TrustedH1Helper.resolve(.supervisor, relativeTo: linkedController)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiSyncTrustedHelper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeExecutable(
        named name: String,
        in directory: URL,
        mode: mode_t = 0o755
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        guard chmod(url.path, mode) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }
}

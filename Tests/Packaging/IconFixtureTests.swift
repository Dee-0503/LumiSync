import Foundation
import XCTest

final class IconFixtureTests: XCTestCase {
    func testVerifierRejectsICNSWithMissingRepresentation() throws {
        let master = try makeRGBAFixture(width: 1024, height: 1024, transparentCorners: true)
        defer { try? FileManager.default.removeItem(at: master) }
        let fixture = try makeICNSFixtureWithout512Representation()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runVerifier(master: master, icns: fixture.icns)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.stderr.contains("missing ICNS representation files: icon_512x512.png"),
            "Expected missing-representation diagnostic, got: \(result.stderr)"
        )
    }

    func testVerifierRejectsProductionMasterPNGDirectly() throws {
        let result = try runVerifier(master: repositoryMaster, icns: repositoryICNS)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.stderr.contains("master PNG must be 1024x1024") ||
                result.stderr.contains("master PNG must be 8-bit RGBA"),
            "Expected production-master diagnostic, got: \(result.stderr)"
        )
    }

    func testVerifierRejectsOpaqueSquareCanvas() throws {
        let fixture = try makeRGBAFixture(width: 1024, height: 1024, transparentCorners: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = try runVerifier(master: fixture, icns: repositoryICNS)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.stderr.contains("transparent outer corners"),
            "Expected transparent-corner diagnostic, got: \(result.stderr)"
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repositoryMaster: URL {
        repositoryRoot.appendingPathComponent("design/lumisync-app-icon.png")
    }

    private var repositoryICNS: URL {
        repositoryRoot.appendingPathComponent("Packaging/LumiSync/Resources/LumiSync.icns")
    }

    private func runVerifier(master: URL, icns: URL) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            repositoryRoot.appendingPathComponent("Scripts/verify-app-icon.py").path,
            "--master", master.path,
            "--icns", icns.path,
        ]
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func makeICNSFixtureWithout512Representation() throws -> (root: URL, icns: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiSyncIconFixture-\(UUID().uuidString)", isDirectory: true)
        let iconset = root.appendingPathComponent("LumiSync.iconset", isDirectory: true)
        let sourceIconset = root.appendingPathComponent("Source.iconset", isDirectory: true)
        let icns = root.appendingPathComponent("Missing512.icns")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

        let extraction = Process()
        extraction.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        extraction.arguments = ["-c", "iconset", "-o", sourceIconset.path, repositoryICNS.path]
        try extraction.run()
        extraction.waitUntilExit()
        XCTAssertEqual(extraction.terminationStatus, 0)

        for source in try FileManager.default.contentsOfDirectory(
            at: sourceIconset,
            includingPropertiesForKeys: nil
        ) where source.lastPathComponent != "icon_512x512.png" {
            try FileManager.default.copyItem(
                at: source,
                to: iconset.appendingPathComponent(source.lastPathComponent)
            )
        }

        let packaging = Process()
        packaging.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        packaging.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
        try packaging.run()
        packaging.waitUntilExit()
        XCTAssertEqual(packaging.terminationStatus, 0)
        return (root, icns)
    }

    private func makeRGBAFixture(width: Int, height: Int, transparentCorners: Bool) throws -> URL {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let generator = Process()
        generator.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        generator.arguments = [
            "-c",
            Self.pngGenerator,
            fixture.path,
            String(width),
            String(height),
            transparentCorners ? "transparent" : "opaque",
        ]
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        return fixture
    }

    private static let pngGenerator = #"""
import binascii
import struct
import sys
import zlib

path, width, height, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xffffffff)

rows = []
for y in range(height):
    pixels = bytearray()
    for x in range(width):
        alpha = 255
        if mode == "transparent" and (x < 128 or x >= width - 128) and (y < 128 or y >= height - 128):
            alpha = 0
        pixels.extend((40, 80, 120, alpha))
    rows.append(b"\x00" + pixels)
raw = b"".join(rows)
png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(raw))
png += chunk(b"IEND", b"")
open(path, "wb").write(png)
"""#
}

import Foundation
import XCTest

final class IconFixtureTests: XCTestCase {
    func testVerifierRejectsOpaqueSquareCanvas() throws {
        let fixture = try makeOpaqueRGBAFixture(width: 1024, height: 1024)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = try runVerifier(master: fixture, icns: repositoryICNS)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.stderr.contains("transparent outer corners"),
            "Expected transparent-corner diagnostic, got: \(result.stderr)"
        )
    }

    func testVerifierAcceptsTransparentCornersAndCompleteICNSRepresentations() throws {
        let fixture = try makeTransparentRGBAFixture(width: 1024, height: 1024)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = try runVerifier(master: fixture, icns: repositoryICNS)

        XCTAssertEqual(result.status, 0, result.stderr)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    private func makeTransparentRGBAFixture(width: Int, height: Int) throws -> URL {
        try makeRGBAFixture(width: width, height: height, transparentCorners: true)
    }

    private func makeOpaqueRGBAFixture(width: Int, height: Int) throws -> URL {
        try makeRGBAFixture(width: width, height: height, transparentCorners: false)
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

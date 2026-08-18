import Darwin
import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class LumiSyncKeyboardProbeProcessTests: XCTestCase {
    func testMalformedInputIsRejectedWithoutMutation() async throws {
        let harness = try ProcessHarness()
        let result = await harness.run(input: Data(), timeout: .seconds(2))
        XCTAssertNotEqual(result.termination, .exited)
        XCTAssertEqual(try harness.currentValue(), try NormalizedBacklightValue(0.37))
    }
}

private struct ProcessResult {
    let termination: OwnedProcessTermination
    let stdout: Data
    let stderr: Data
}

private final class ProcessHarness {
    private let directory: URL
    private let controllerURL: URL
    private let supervisorURL: URL
    private let writerURL: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiSyncProcessTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        self.directory = directory
        controllerURL = try Self.executable(named: "lumisync-backlight-controller")
        supervisorURL = try Self.executable(named: "lumisync-backlight-supervisor")
        writerURL = try Self.executable(named: "lumisync-backlight-writer")
        try FileBackedFakeBacklightDevice.create(
            directory: directory,
            configuration: FakeBacklightDeviceConfiguration(initialValue: try NormalizedBacklightValue(0.37))
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func run(input: Data, timeout: Duration) async -> ProcessResult {
        let result = await BoundedOwnedProcessRunner().run(
            OwnedProcessRequest(
                executableURL: controllerURL,
                standardInput: input,
                timeout: timeout,
                environment: [
                    "LUMISYNC_H1_SUPERVISOR_PATH": supervisorURL.path,
                    "LUMISYNC_H1_WRITER_PATH": writerURL.path,
                    "LUMISYNC_H1_FAKE_DEVICE_DIR": directory.path
                ]
            )
        )
        return ProcessResult(termination: result.termination, stdout: result.stdout, stderr: result.stderr)
    }

    func currentValue() throws -> NormalizedBacklightValue {
        try FileBackedFakeBacklightDevice(directory: directory).read(
            requestID: try BacklightRequestID(rawValue: "harness-read")
        )
    }

    private static func executable(named name: String) throws -> URL {
        var base = Bundle(for: LumiSyncKeyboardProbeProcessTests.self).bundleURL
        for _ in 0..<5 {
            let candidate = base.deletingLastPathComponent().appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            base = base.deletingLastPathComponent()
        }
        throw NSError(domain: "LumiSyncKeyboardProbeProcessTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Unable to locate SwiftPM product \(name)"
        ])
    }
}

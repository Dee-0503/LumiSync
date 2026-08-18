import Darwin
import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class LumiSyncKeyboardProbeProcessTests: XCTestCase {
    func testSetRequestTraversesControllerSupervisorWriterAndReturnsReadback() async throws {
        let harness = try ProcessHarness(initialValue: 0.37)
        let request = try harness.makeRequest(
            requestID: "normal-set",
            operation: .set(try NormalizedBacklightValue(0.5))
        )

        let result = await harness.run(
            input: try FramedJSONCodec().encode(request),
            timeout: .seconds(2)
        )

        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(
            try FramedJSONCodec().decode(BacklightOperationResult.self, from: result.stdout),
            .success(readback: try NormalizedBacklightValue(0.5))
        )
        let journalEntries = try harness.journalEntries()
        XCTAssertEqual(try harness.currentValue(), try NormalizedBacklightValue(0.37))
        XCTAssertEqual(
            journalEntries.map { "\($0.processRole.rawValue):\($0.operationCategory.rawValue):\($0.value.rawValue)" },
            [
                "writer:read:0.37",
                "writer:set:0.5",
                "writer:read:0.5",
                "writer:restore:0.37",
                "writer:read:0.37"
            ]
        )
    }

    func testMalformedInputIsRejectedWithoutMutation() async throws {
        let harness = try ProcessHarness()
        let result = await harness.run(input: Data(), timeout: .seconds(2))
        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(
            try FramedJSONCodec().decode(BacklightOperationResult.self, from: result.stdout),
            .failure(primary: .protocolViolation, restoration: .notRequired)
        )
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

    init(initialValue: Double = 0.37) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiSyncProcessTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        self.directory = directory
        controllerURL = try Self.executable(named: "lumisync-backlight-controller")
        supervisorURL = try Self.executable(named: "lumisync-backlight-supervisor")
        writerURL = try Self.executable(named: "lumisync-backlight-writer")
        try FileBackedFakeBacklightDevice.create(
            directory: directory,
            configuration: FakeBacklightDeviceConfiguration(initialValue: try NormalizedBacklightValue(initialValue))
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

    func makeRequest(requestID: String, operation: BacklightOperation) throws -> BacklightRequest {
        BacklightRequest(
            requestID: try BacklightRequestID(rawValue: requestID),
            operation: operation,
            deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000)
        )
    }

    func journalEntries() throws -> [FakeBacklightJournalEntry] {
        try FileBackedFakeBacklightDevice(directory: directory).journalEntries()
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

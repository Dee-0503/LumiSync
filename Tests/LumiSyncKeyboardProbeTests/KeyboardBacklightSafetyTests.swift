import XCTest
@testable import LumiSyncKeyboardProbe

final class KeyboardBacklightSafetyTests: XCTestCase {
    func testReadOnlyProbeNeverWrites() throws {
        let backend = RecordingKeyboardBacklightBackend(originalBrightness: 0.37)

        let result = try KeyboardBacklightProbe(backend: backend).inspect()

        XCTAssertEqual(result.keyboards, [
            KeyboardBacklightSnapshot(id: 42, isBuiltIn: true, brightness: 0.37)
        ])
        XCTAssertEqual(backend.operations, [.list, .isBuiltIn(42), .read(42)])
    }

    func testWriteTestVisitsRequiredLevelsThenRestoresOriginal() throws {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            readbacks: [0.37, 0.0, 0.5, 1.0]
        )
        let runner = KeyboardBacklightWriteTest(backend: backend)

        let result = try runner.run(keyboardID: 42)

        XCTAssertEqual(result.originalBrightness, 0.37)
        XCTAssertEqual(result.verifiedLevels, [0.0, 0.5, 1.0])
        XCTAssertEqual(backend.operations, [
            .read(42),
            .installRecovery(42, 0.37),
            .write(42, 0.0), .read(42),
            .write(42, 0.5), .read(42),
            .write(42, 1.0), .read(42),
            .restore(42, 0.37),
            .disarmRecovery
        ])
    }

    func testWriteFailureRestoresOriginalBeforeRethrowing() {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            failure: .write(42, 0.5)
        )
        let runner = KeyboardBacklightWriteTest(backend: backend)

        XCTAssertThrowsError(try runner.run(keyboardID: 42))
        XCTAssertEqual(backend.operations.suffix(2), [
            .restore(42, 0.37),
            .disarmRecovery
        ])
    }

    func testWriteTestRefusesNonFiniteOriginalBeforeRecoveryOrWrite() {
        let backend = RecordingKeyboardBacklightBackend(originalBrightness: .nan)
        let runner = KeyboardBacklightWriteTest(backend: backend)

        XCTAssertThrowsError(try runner.run(keyboardID: 42))
        XCTAssertEqual(backend.operations, [.read(42)])
    }

    func testWriteTestRefusesToWriteWhenRecoveryCannotBeInstalled() {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            failure: .installRecovery(42, 0.37)
        )
        let runner = KeyboardBacklightWriteTest(backend: backend)

        XCTAssertThrowsError(try runner.run(keyboardID: 42))
        XCTAssertFalse(backend.operations.contains { operation in
            if case .write = operation { return true }
            return false
        })
    }

    func testRestoreFailureKeepsEmergencyRecoveryArmed() {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            failure: .restore(42, 0.37),
            readbacks: [0.37, 0.0, 0.5, 1.0]
        )
        let runner = KeyboardBacklightWriteTest(backend: backend)

        XCTAssertThrowsError(try runner.run(keyboardID: 42))
        XCTAssertEqual(backend.operations.last, .restore(42, 0.37))
        XCTAssertFalse(backend.operations.contains(.disarmRecovery))
    }

    func testDefaultCommandIsReadOnlyInspection() throws {
        XCTAssertEqual(try KeyboardBacklightCommand(arguments: []), .inspect)
    }

    func testWriteCommandRemainsBlockedEvenWithBothExplicitFlags() {
        XCTAssertThrowsError(try KeyboardBacklightCommand(arguments: ["--unsafe-write-test"]))
        XCTAssertThrowsError(try KeyboardBacklightCommand(arguments: ["--confirm-restore"]))
        XCTAssertThrowsError(
            try KeyboardBacklightCommand(arguments: [
                "--unsafe-write-test",
                "--confirm-restore"
            ])
        )
    }

    func testReadbackMismatchRestoresOriginalAndFails() {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            readbacks: [0.37, 0.0, 0.4]
        )
        let runner = KeyboardBacklightWriteTest(backend: backend)

        XCTAssertThrowsError(try runner.run(keyboardID: 42))
        XCTAssertEqual(backend.operations.suffix(2), [
            .restore(42, 0.37),
            .disarmRecovery
        ])
    }
}

private final class RecordingKeyboardBacklightBackend: KeyboardBacklightBackend {
    enum Operation: Equatable {
        case list
        case isBuiltIn(UInt64)
        case read(UInt64)
        case installRecovery(UInt64, Float)
        case write(UInt64, Float)
        case restore(UInt64, Float)
        case disarmRecovery
    }

    enum Failure: Error {
        case requested(Operation)
    }

    private let originalBrightness: Float
    private let failure: Operation?
    private var readbacks: [Float]
    private(set) var operations: [Operation] = []

    init(
        originalBrightness: Float,
        failure: Operation? = nil,
        readbacks: [Float] = []
    ) {
        self.originalBrightness = originalBrightness
        self.failure = failure
        self.readbacks = readbacks
    }

    func keyboardIDs() throws -> [UInt64] {
        try record(.list)
        return [42]
    }

    func isBuiltIn(keyboardID: UInt64) throws -> Bool {
        try record(.isBuiltIn(keyboardID))
        return true
    }

    func brightness(keyboardID: UInt64) throws -> Float {
        try record(.read(keyboardID))
        return readbacks.isEmpty ? originalBrightness : readbacks.removeFirst()
    }

    func installRecovery(keyboardID: UInt64, originalBrightness: Float) throws {
        try record(.installRecovery(keyboardID, originalBrightness))
    }

    func setBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        try record(.write(keyboardID, brightness))
    }

    func restoreBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        try record(.restore(keyboardID, brightness))
    }

    func disarmRecovery() {
        operations.append(.disarmRecovery)
    }

    private func record(_ operation: Operation) throws {
        operations.append(operation)
        if operation == failure {
            throw Failure.requested(operation)
        }
    }
}

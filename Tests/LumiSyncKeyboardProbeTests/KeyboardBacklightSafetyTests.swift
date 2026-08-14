import Darwin
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

    func testWriterVisitsRequiredLevelsAndVerifiesReadbacks() throws {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            readbacks: [0.0, 0.5, 1.0]
        )

        let result = try KeyboardBacklightWriter(backend: backend).run(keyboardID: 42)

        XCTAssertEqual(result.verifiedLevels, [0.0, 0.5, 1.0])
        XCTAssertEqual(backend.operations, [
            .write(42, 0.0), .read(42),
            .write(42, 0.5), .read(42),
            .write(42, 1.0), .read(42)
        ])
    }

    func testWriterFailsOnReadbackMismatch() {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            readbacks: [0.0, 0.4]
        )

        XCTAssertThrowsError(try KeyboardBacklightWriter(backend: backend).run(keyboardID: 42))
        XCTAssertEqual(backend.operations, [
            .write(42, 0.0), .read(42),
            .write(42, 0.5), .read(42)
        ])
    }

    func testWatchdogOwnsOriginalAndRestoresAfterNormalCompletion() throws {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            readbacks: [0.37, 0.37]
        )
        let child = RecordingChildRunner(termination: .exited(0))

        let result = try KeyboardBacklightRecoveryWatchdog(
            backend: backend,
            childRunner: child
        ).run(keyboardID: 42)

        XCTAssertEqual(result.originalBrightness, 0.37)
        XCTAssertEqual(child.keyboardIDs, [42])
        XCTAssertEqual(backend.operations, [
            .read(42),
            .restore(42, 0.37),
            .read(42)
        ])
    }

    func testWatchdogRestoresForEveryAbnormalChildTermination() {
        let terminations: [KeyboardBacklightChildTermination] = [
            .exited(70),
            .signaled(SIGINT),
            .signaled(SIGTERM),
            .signaled(SIGABRT),
            .signaled(SIGKILL)
        ]

        for termination in terminations {
            let backend = RecordingKeyboardBacklightBackend(
                originalBrightness: 0.37,
                readbacks: [0.37, 0.37]
            )
            let child = RecordingChildRunner(termination: termination)

            XCTAssertThrowsError(
                try KeyboardBacklightRecoveryWatchdog(
                    backend: backend,
                    childRunner: child
                ).run(keyboardID: 42),
                "termination=\(termination)"
            )
            XCTAssertEqual(backend.operations.suffix(2), [
                .restore(42, 0.37),
                .read(42)
            ])
        }
    }

    func testWatchdogRestoresWhenChildLaunchThrows() {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            readbacks: [0.37, 0.37]
        )
        let child = RecordingChildRunner(error: TestError.requested)

        XCTAssertThrowsError(
            try KeyboardBacklightRecoveryWatchdog(
                backend: backend,
                childRunner: child
            ).run(keyboardID: 42)
        )
        XCTAssertEqual(backend.operations.suffix(2), [
            .restore(42, 0.37),
            .read(42)
        ])
    }

    func testWatchdogRefusesToLaunchForInvalidOriginalBrightness() {
        let backend = RecordingKeyboardBacklightBackend(originalBrightness: .nan)
        let child = RecordingChildRunner(termination: .exited(0))

        XCTAssertThrowsError(
            try KeyboardBacklightRecoveryWatchdog(
                backend: backend,
                childRunner: child
            ).run(keyboardID: 42)
        )
        XCTAssertTrue(child.keyboardIDs.isEmpty)
        XCTAssertEqual(backend.operations, [.read(42)])
    }

    func testWatchdogFailsClosedWhenRestorationCannotBeVerified() {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            readbacks: [0.37, 0.25]
        )
        let child = RecordingChildRunner(termination: .exited(0))

        XCTAssertThrowsError(
            try KeyboardBacklightRecoveryWatchdog(
                backend: backend,
                childRunner: child
            ).run(keyboardID: 42)
        )
        XCTAssertEqual(backend.operations.suffix(2), [
            .restore(42, 0.37),
            .read(42)
        ])
    }

    func testWatchdogPrioritizesRestoreFailureOverChildFailure() {
        let backend = RecordingKeyboardBacklightBackend(
            originalBrightness: 0.37,
            failure: .restore(42, 0.37),
            readbacks: [0.37]
        )
        let child = RecordingChildRunner(termination: .signaled(SIGKILL))

        XCTAssertThrowsError(
            try KeyboardBacklightRecoveryWatchdog(
                backend: backend,
                childRunner: child
            ).run(keyboardID: 42)
        ) { error in
            guard case KeyboardBacklightWatchdogError.restoreFailed = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
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

    func testWriteCommandRejectsDuplicateOrUnknownFlags() {
        XCTAssertThrowsError(
            try KeyboardBacklightCommand(arguments: [
                "--unsafe-write-test",
                "--confirm-restore",
                "--confirm-restore"
            ])
        )
        XCTAssertThrowsError(try KeyboardBacklightCommand(arguments: ["--internal-writer"]))
    }
}

private enum TestError: Error {
    case requested
}

private final class RecordingChildRunner: KeyboardBacklightChildRunning {
    private let termination: KeyboardBacklightChildTermination?
    private let error: Error?
    private(set) var keyboardIDs: [UInt64] = []

    init(termination: KeyboardBacklightChildTermination) {
        self.termination = termination
        error = nil
    }

    init(error: Error) {
        termination = nil
        self.error = error
    }

    func runWriter(keyboardID: UInt64) throws -> KeyboardBacklightChildTermination {
        keyboardIDs.append(keyboardID)
        if let error {
            throw error
        }
        return try XCTUnwrap(termination)
    }
}

private final class RecordingKeyboardBacklightBackend: KeyboardBacklightBackend {
    enum Operation: Equatable {
        case list
        case isBuiltIn(UInt64)
        case read(UInt64)
        case write(UInt64, Float)
        case restore(UInt64, Float)
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

    func setBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        try record(.write(keyboardID, brightness))
    }

    func restoreBrightness(_ brightness: Float, keyboardID: UInt64) throws {
        try record(.restore(keyboardID, brightness))
    }

    private func record(_ operation: Operation) throws {
        operations.append(operation)
        if operation == failure {
            throw Failure.requested(operation)
        }
    }
}

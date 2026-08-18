import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class SafetySupervisorTests: XCTestCase {
    func testSupervisorCapturesOriginalBeforeMutationAndRestoresAfterSuccess() async throws {
        let runner = ScriptedOwnedProcessRunner(results: [
            writerSuccess(0.37),
            writerSuccess(0.5),
            writerSuccess(0.37)
        ])
        let supervisor = BacklightSafetySupervisor(
            runner: runner,
            configuration: BacklightSupervisorConfiguration(
                writerExecutableURL: URL(fileURLWithPath: "/tmp/fake-writer"),
                fakeDeviceDirectory: URL(fileURLWithPath: "/tmp/fake-device")
            )
        )

        let result = await supervisor.execute(try makeSetRequest(0.5))

        XCTAssertEqual(result, .success(readback: try NormalizedBacklightValue(0.5)))
        let operations = await runner.recordedOperations()
        XCTAssertEqual(operations, [.read, .set(0.5), .restore(0.37)])
    }

    private func makeSetRequest(_ value: Double) throws -> BacklightRequest {
        BacklightRequest(
            requestID: try BacklightRequestID(rawValue: "supervisor-test"),
            operation: .set(try NormalizedBacklightValue(value)),
            deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000)
        )
    }

    private func writerSuccess(_ value: Double) -> OwnedProcessResult {
        let normalized = try! NormalizedBacklightValue(value)
        let result = BacklightOperationResult.success(readback: normalized)
        return OwnedProcessResult(
            termination: .exited,
            exitStatus: 0,
            stdout: try! FramedJSONCodec().encode(result),
            stderr: Data(),
            rootPID: 1,
            cleanupVerified: true
        )
    }
}

private actor ScriptedOwnedProcessRunner: OwnedProcessRunning {
    enum Operation: Equatable {
        case read
        case set(Double)
        case restore(Double)
    }

    private var results: [OwnedProcessResult]
    private var operations: [Operation] = []

    init(results: [OwnedProcessResult]) {
        self.results = results
    }

    func recordedOperations() -> [Operation] {
        operations
    }

    func run(_ request: OwnedProcessRequest) async -> OwnedProcessResult {
        let decoded = try! FramedJSONCodec().decode(BacklightRequest.self, from: request.standardInput)
        switch decoded.operation {
        case .read:
            operations.append(.read)
        case .set(let value):
            operations.append(.set(value.rawValue))
        case .restore(let value):
            operations.append(.restore(value.rawValue))
        }
        return results.removeFirst()
    }
}

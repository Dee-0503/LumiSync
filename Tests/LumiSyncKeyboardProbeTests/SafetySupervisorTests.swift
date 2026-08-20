import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class SafetySupervisorTests: XCTestCase {
    func testSupervisorCapturesOriginalBeforeMutationAndRestoresAfterSuccess() async throws {
        let runner = ScriptedOwnedProcessRunner(results: [writerSuccess(0.37), writerSuccess(0.5), writerSuccess(0.37)])
        let supervisor = BacklightSafetySupervisor(runner: runner, configuration: configuration())
        let result = await supervisor.execute(try makeSetRequest(0.5))
        XCTAssertEqual(result, .success(readback: try NormalizedBacklightValue(0.5)))
        let history = await runner.history()
        XCTAssertEqual(history, [.read, .set(0.5), .restore(0.37)])
    }

    func testSupervisorRestoresAfterWriterFailure() async throws {
        let runner = ScriptedOwnedProcessRunner(results: [writerSuccess(0.37), .failure(primary: .writerFailed, restoration: .notRequired), writerSuccess(0.37)])
        let supervisor = BacklightSafetySupervisor(runner: runner, configuration: configuration())
        let result = await supervisor.execute(try makeSetRequest(0.5))
        XCTAssertEqual(result, .failure(primary: .writerFailed, restoration: .verified(try NormalizedBacklightValue(0.37))))
        let history = await runner.history()
        XCTAssertEqual(history, [.read, .set(0.5), .restore(0.37)])
    }

    func testSupervisorRestorationFailureOverridesPrimaryResult() async throws {
        let runner = ScriptedOwnedProcessRunner(results: [writerSuccess(0.37), writerSuccess(0.5), .failure(primary: .writerFailed, restoration: .notRequired)])
        let supervisor = BacklightSafetySupervisor(runner: runner, configuration: configuration())
        let result = await supervisor.execute(try makeSetRequest(0.5))
        XCTAssertEqual(result, .failure(primary: .restorationFailed, restoration: .failed))
    }

    func testSupervisorChildBudgetsDoNotExceedParentDeadline() async throws {
        let parentNanoseconds: UInt64 = 750_000_000
        let runner = ScriptedOwnedProcessRunner(
            results: [writerSuccess(0.37), writerSuccess(0.5), writerSuccess(0.37)]
        )
        let supervisor = BacklightSafetySupervisor(runner: runner, configuration: configuration())
        let request = BacklightRequest(
            requestID: try BacklightRequestID(rawValue: "deadline-test"),
            operation: .set(try NormalizedBacklightValue(0.5)),
            deadline: try BacklightDeadline(remainingNanoseconds: parentNanoseconds)
        )

        _ = await supervisor.execute(request)

        let childRequests = await runner.requests()
        XCTAssertEqual(childRequests.count, 3)
        var previousRemaining = parentNanoseconds
        for childProcessRequest in childRequests {
            let childRequest = try FramedJSONCodec().decode(
                BacklightRequest.self,
                from: childProcessRequest.standardInput
            )
            XCTAssertLessThanOrEqual(
                childRequest.deadline.remainingNanoseconds,
                previousRemaining
            )
            XCTAssertEqual(
                childProcessRequest.timeout,
                .nanoseconds(Int64(childRequest.deadline.remainingNanoseconds))
            )
            previousRemaining = childRequest.deadline.remainingNanoseconds
        }
    }

    private func configuration() -> BacklightSupervisorConfiguration {
        BacklightSupervisorConfiguration(writerExecutableURL: URL(fileURLWithPath: "/tmp/writer"), fakeDeviceDirectory: URL(fileURLWithPath: "/tmp/fake", isDirectory: true))
    }
    private func makeSetRequest(_ value: Double) throws -> BacklightRequest {
        BacklightRequest(requestID: try BacklightRequestID(rawValue: "supervisor-test"), operation: .set(try NormalizedBacklightValue(value)), deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000))
    }
    private func writerSuccess(_ value: Double) -> BacklightOperationResult { .success(readback: try! NormalizedBacklightValue(value)) }
}

private actor ScriptedOwnedProcessRunner: OwnedProcessRunning {
    enum Operation: Equatable { case read, set(Double), restore(Double) }
    private var scripted: [BacklightOperationResult]
    private var recorded: [Operation] = []
    private var recordedRequests: [OwnedProcessRequest] = []
    init(results: [BacklightOperationResult]) { scripted = results }
    func history() -> [Operation] { recorded }
    func requests() -> [OwnedProcessRequest] { recordedRequests }
    func run(_ request: OwnedProcessRequest) async -> OwnedProcessResult {
        let operation: Operation
        switch request.arguments.first {
        case "read": operation = .read
        case "set": operation = .set(Double(request.arguments.dropFirst().first ?? "0") ?? 0)
        case "restore": operation = .restore(Double(request.arguments.dropFirst().first ?? "0") ?? 0)
        default: operation = .read
        }
        recorded.append(operation)
        recordedRequests.append(request)
        let result = scripted.removeFirst()
        return OwnedProcessResult(termination: .exited, exitStatus: 0, stdout: try! FramedJSONCodec().encode(result), stderr: Data(), rootPID: nil, cleanupVerified: true)
    }
}

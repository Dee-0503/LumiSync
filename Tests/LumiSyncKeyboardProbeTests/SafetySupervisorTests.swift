import Darwin
import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class SafetySupervisorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testSupervisorCapturesOriginalBeforeMutationAndRestoresAfterSuccess() async throws {
        let runner = ScriptedOwnedProcessRunner(results: [writerSuccess(0.37), writerSuccess(0.5), writerSuccess(0.37)])
        let supervisor = BacklightSafetySupervisor(runner: runner, configuration: configuration())
        let result = await supervisor.execute(try makeSetRequest(0.5))
        XCTAssertEqual(result, .success(readback: try NormalizedBacklightValue(0.5)))
        let history = await runner.history()
        XCTAssertEqual(history, [.read, .set(0.5), .restore(0.37)])
    }

    func testSupervisorRejectsMutationReadbackThatMissesTargetAndStillRestores() async throws {
        let runner = ScriptedOwnedProcessRunner(
            results: [writerSuccess(0.37), writerSuccess(0.8), writerSuccess(0.37)]
        )
        let supervisor = BacklightSafetySupervisor(runner: runner, configuration: configuration())

        let result = await supervisor.execute(try makeSetRequest(0.5))

        XCTAssertEqual(
            result,
            .failure(
                primary: .readbackMismatch,
                restoration: .verified(try NormalizedBacklightValue(0.37))
            )
        )
        let history = await runner.history()
        XCTAssertEqual(history, [.read, .set(0.5), .restore(0.37)])
    }

    func testSupervisorRejectsDirectRestoreReadbackThatMissesTarget() async throws {
        let runner = ScriptedOwnedProcessRunner(results: [writerSuccess(0.8)])
        let supervisor = BacklightSafetySupervisor(runner: runner, configuration: configuration())
        let request = BacklightRequest(
            requestID: try BacklightRequestID(rawValue: "restore-readback-test"),
            operation: .restore(try NormalizedBacklightValue(0.5)),
            deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000)
        )

        let result = await supervisor.execute(request)

        XCTAssertEqual(
            result,
            .failure(primary: .readbackMismatch, restoration: .notRequired)
        )
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

    func testSupervisorCapsEachChildProcessAtHalfASecond() async throws {
        let runner = ScriptedOwnedProcessRunner(
            results: [writerSuccess(0.37), writerSuccess(0.5), writerSuccess(0.37)]
        )
        let supervisor = BacklightSafetySupervisor(runner: runner, configuration: configuration())
        let request = BacklightRequest(
            requestID: try BacklightRequestID(rawValue: "child-cap-test"),
            operation: .set(try NormalizedBacklightValue(0.5)),
            deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000)
        )

        _ = await supervisor.execute(request)

        let childRequests = await runner.requests()
        XCTAssertEqual(childRequests.count, 3)
        for childProcessRequest in childRequests {
            XCTAssertLessThanOrEqual(childProcessRequest.timeout, .milliseconds(500))
            let childRequest = try FramedJSONCodec().decode(
                BacklightRequest.self,
                from: childProcessRequest.standardInput
            )
            XCTAssertLessThanOrEqual(
                childRequest.deadline.remainingNanoseconds,
                500_000_000
            )
        }
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

    func testSupervisorUsesIndependentRecoveryBudgetAfterMutationTimeout() async throws {
        let runner = ScriptedOwnedProcessRunner(
            processResults: [
                writerProcessResult(0.37),
                timedOutProcessResult(),
                writerProcessResult(0.37)
            ]
        )
        let supervisor = BacklightSafetySupervisor(runner: runner, configuration: configuration())
        let parentNanoseconds: UInt64 = 100_000_000
        let request = BacklightRequest(
            requestID: try BacklightRequestID(rawValue: "recovery-budget-test"),
            operation: .set(try NormalizedBacklightValue(0.5)),
            deadline: try BacklightDeadline(remainingNanoseconds: parentNanoseconds)
        )

        let result = await supervisor.execute(request)

        XCTAssertEqual(
            result,
            .failure(
                primary: .timedOut(stage: .write),
                restoration: .verified(try NormalizedBacklightValue(0.37))
            )
        )
        let requests = await runner.requests()
        XCTAssertEqual(requests.count, 3)
        let restoreRequest = try FramedJSONCodec().decode(
            BacklightRequest.self,
            from: requests[2].standardInput
        )
        XCTAssertGreaterThan(restoreRequest.deadline.remainingNanoseconds, parentNanoseconds)
        XCTAssertLessThanOrEqual(
            restoreRequest.deadline.remainingNanoseconds,
            BacklightSafetySupervisor.recoveryBudgetNanoseconds
        )
    }

    func testSupervisorDoesNotVerifyRecoveryAfterUnverifiedWriterTimeout() async throws {
        let runner = ScriptedOwnedProcessRunner(
            processResults: [
                writerProcessResult(0.37),
                timedOutProcessResult(cleanupVerified: false),
                writerProcessResult(0.37)
            ]
        )
        let supervisor = BacklightSafetySupervisor(runner: runner, configuration: configuration())

        let result = await supervisor.execute(try makeSetRequest(0.5))

        XCTAssertEqual(
            result,
            .failure(primary: .restorationUncertain, restoration: .uncertain)
        )
        let history = await runner.history()
        XCTAssertEqual(history, [.read, .set(0.5)])
    }

    func testRestoreTimeoutWithUnreadableJournalIsUncertain() async throws {
        let directory = try makeTemporaryFakeDevice()
        try Data("not-json\n".utf8).write(
            to: directory.appendingPathComponent("journal.jsonl")
        )
        let runner = ScriptedOwnedProcessRunner(
            processResults: [timedOutProcessResult()]
        )
        let supervisor = BacklightSafetySupervisor(
            runner: runner,
            configuration: configuration(fakeDeviceDirectory: directory)
        )

        let result = await supervisor.execute(try makeSetRequest(0.5))

        XCTAssertEqual(
            result,
            .failure(primary: .timedOut(stage: .captureOriginal), restoration: .notRequired)
        )

        let restoreRunner = ScriptedOwnedProcessRunner(
            processResults: [writerProcessResult(0.37), timedOutProcessResult(), timedOutProcessResult()]
        )
        let restoreSupervisor = BacklightSafetySupervisor(
            runner: restoreRunner,
            configuration: configuration(fakeDeviceDirectory: directory)
        )
        let restoreResult = await restoreSupervisor.execute(try makeSetRequest(0.5))
        XCTAssertEqual(
            restoreResult,
            .failure(primary: .restorationUncertain, restoration: .uncertain)
        )
    }

    func testMutationTimeoutUsesRecoveredCommittedJournalAsWriteReadbackEvidence() async throws {
        let directory = try makeTemporaryFakeDevice()
        let requestID = try BacklightRequestID(rawValue: "supervisor-test")
        let failedDevice = try FileBackedFakeBacklightDevice(
            directory: directory,
            systemCalls: ScriptedSupervisorSystemCalls(failCommitSync: true)
        )
        XCTAssertThrowsError(
            try failedDevice.write(
                try NormalizedBacklightValue(0.5),
                requestID: requestID
            )
        )
        let runner = ScriptedOwnedProcessRunner(
            processResults: [writerProcessResult(0.37), timedOutProcessResult(), writerProcessResult(0.37)]
        )
        let supervisor = BacklightSafetySupervisor(
            runner: runner,
            configuration: configuration(fakeDeviceDirectory: directory)
        )

        let result = await supervisor.execute(try makeSetRequest(0.5))

        XCTAssertEqual(
            result,
            .failure(
                primary: .timedOut(stage: .writeReadback),
                restoration: .verified(try NormalizedBacklightValue(0.37))
            )
        )
    }

    private func configuration(
        fakeDeviceDirectory: URL = URL(fileURLWithPath: "/tmp/fake", isDirectory: true)
    ) -> BacklightSupervisorConfiguration {
        BacklightSupervisorConfiguration(
            writerExecutableURL: URL(fileURLWithPath: "/tmp/writer"),
            fakeDeviceDirectory: fakeDeviceDirectory
        )
    }

    private func makeTemporaryFakeDevice() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumiSyncSupervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryDirectories.append(directory)
        try FileBackedFakeBacklightDevice.create(
            directory: directory,
            configuration: FakeBacklightDeviceConfiguration(
                initialValue: try NormalizedBacklightValue(0.37)
            )
        )
        return directory
    }

    private func timedOutProcessResult(
        cleanupVerified: Bool = true
    ) -> OwnedProcessResult {
        OwnedProcessResult(
            termination: .timedOut,
            exitStatus: nil,
            stdout: Data(),
            stderr: Data(),
            rootPID: nil,
            cleanupVerified: cleanupVerified
        )
    }

    private func writerProcessResult(_ value: Double) -> OwnedProcessResult {
        OwnedProcessResult(
            termination: .exited,
            exitStatus: 0,
            stdout: try! FramedJSONCodec().encode(writerSuccess(value)),
            stderr: Data(),
            rootPID: nil,
            cleanupVerified: true
        )
    }

    private func makeSetRequest(_ value: Double) throws -> BacklightRequest {
        BacklightRequest(requestID: try BacklightRequestID(rawValue: "supervisor-test"), operation: .set(try NormalizedBacklightValue(value)), deadline: try BacklightDeadline(remainingNanoseconds: 2_000_000_000))
    }
    private func writerSuccess(_ value: Double) -> BacklightOperationResult { .success(readback: try! NormalizedBacklightValue(value)) }
}

private actor ScriptedOwnedProcessRunner: OwnedProcessRunning {
    enum Operation: Equatable { case read, set(Double), restore(Double) }
    private var scripted: [OwnedProcessResult]
    private var recorded: [Operation] = []
    private var recordedRequests: [OwnedProcessRequest] = []

    init(results: [BacklightOperationResult]) {
        scripted = results.map { result in
            OwnedProcessResult(
                termination: .exited,
                exitStatus: 0,
                stdout: try! FramedJSONCodec().encode(result),
                stderr: Data(),
                rootPID: nil,
                cleanupVerified: true
            )
        }
    }

    init(processResults: [OwnedProcessResult]) {
        scripted = processResults
    }

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
        return scripted.removeFirst()
    }
}

private final class ScriptedSupervisorSystemCalls:
    FakeBacklightSystemCalling,
    @unchecked Sendable {
    private var failCommitSync: Bool
    private let lock = NSLock()

    init(failCommitSync: Bool) {
        self.failCommitSync = failCommitSync
    }

    func beginWrite(_ purpose: FakeBacklightWritePurpose, descriptor: Int32) {}
    func endWrite(descriptor: Int32) {}

    func write(_ descriptor: Int32, buffer: UnsafeRawPointer, count: Int) -> Int {
        Darwin.write(descriptor, buffer, count)
    }

    func fsync(_ descriptor: Int32, purpose: FakeBacklightSyncPurpose) -> Int32 {
        let shouldFail = lock.withLock {
            guard failCommitSync, purpose == .journalCommit else { return false }
            failCommitSync = false
            return true
        }
        if shouldFail {
            errno = EIO
            return -1
        }
        return Darwin.fsync(descriptor)
    }

    func rename(_ source: String, _ destination: String) -> Int32 {
        Darwin.rename(source, destination)
    }

    func ftruncate(_ descriptor: Int32, length: off_t) -> Int32 {
        Darwin.ftruncate(descriptor, length)
    }
}

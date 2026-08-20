import Darwin
import Foundation
import XCTest
@testable import LumiSyncKeyboardProbe

final class ThreeProcessRecoveryTests: XCTestCase {
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

    func testInvalidSafetyValuesAreRejectedBeforeDeviceMutation() async throws {
        let validPayload: [String: Any] = [
            "version": BacklightRequest.currentVersion,
            "requestID": ["rawValue": "valid-request"],
            "operation": ["set": ["_0": ["rawValue": 0.5]]],
            "deadline": ["remainingNanoseconds": 2_000_000_000]
        ]
        let oversizedID = String(repeating: "a", count: 65)
        let invalidInputs: [(String, Data)] = [
            ("empty-request-id", try framedJSON(replacing(
                validPayload, keyPath: ["requestID", "rawValue"], with: ""
            ))),
            ("oversized-request-id", try framedJSON(replacing(
                validPayload, keyPath: ["requestID", "rawValue"], with: oversizedID
            ))),
            ("brightness-below-range", try framedJSON(replacing(
                validPayload, keyPath: ["operation", "set", "_0", "rawValue"], with: -1.0
            ))),
            ("brightness-above-range", try framedJSON(replacing(
                validPayload, keyPath: ["operation", "set", "_0", "rawValue"], with: 2.0
            ))),
            ("non-finite-brightness", framed(Data(
                "{\"version\":1,\"requestID\":{\"rawValue\":\"non-finite\"},\"operation\":{\"set\":{\"_0\":{\"rawValue\":1e999}}},\"deadline\":{\"remainingNanoseconds\":2000000000}}".utf8
            ))),
            ("zero-deadline", try framedJSON(replacing(
                validPayload, keyPath: ["deadline", "remainingNanoseconds"], with: UInt64(0)
            ))),
            ("deadline-above-limit", try framedJSON(replacing(
                validPayload, keyPath: ["deadline", "remainingNanoseconds"], with: UInt64(30_000_000_001)
            ))),
            ("maximum-deadline", framed(Data(
                "{\"version\":1,\"requestID\":{\"rawValue\":\"maximum-deadline\"},\"operation\":{\"set\":{\"_0\":{\"rawValue\":0.5}}},\"deadline\":{\"remainingNanoseconds\":18446744073709551615}}".utf8
            )))
        ]

        for (name, input) in invalidInputs {
            let harness = try ProcessHarness()
            let stateBefore = try harness.stateSnapshot()
            let journalBefore = try harness.journalSnapshot()

            let result = await harness.run(input: input, timeout: .seconds(2))

            XCTAssertEqual(result.termination, .exited, name)
            XCTAssertEqual(result.exitStatus, EX_OK, name)
            XCTAssertTrue(result.cleanupVerified, name)
            XCTAssertLessThanOrEqual(result.stdout.count, 64 * 1024, name)
            XCTAssertLessThanOrEqual(result.stderr.count, 64 * 1024, name)
            XCTAssertTrue(result.stderr.isEmpty, name)
            XCTAssertEqual(
                try FramedJSONCodec().decode(BacklightOperationResult.self, from: result.stdout),
                .failure(primary: .protocolViolation, restoration: .notRequired),
                name
            )
            XCTAssertEqual(try harness.stateSnapshot(), stateBefore, name)
            XCTAssertEqual(try harness.journalSnapshot(), journalBefore, name)
        }
    }

    func testMalformedProtocolIsRejectedWithoutLeakingProcesses() async throws {
        let validHarness = try ProcessHarness()
        let request = try validHarness.makeRequest(
            requestID: "malformed-matrix",
            operation: .set(try NormalizedBacklightValue(0.5))
        )
        let validFrame = try FramedJSONCodec().encode(request)
        let validPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(validFrame.dropFirst(4))) as? [String: Any]
        )
        var unknownVersion = validPayload
        unknownVersion["version"] = BacklightRequest.currentVersion + 1

        let malformedInputs: [(String, Data)] = [
            ("empty", Data()),
            ("truncated-header", Data([0, 0, 0])),
            ("oversized-frame", Data([0, 0, 0x40, 0x01])),
            ("truncated-json", framed(Data("{".utf8))),
            ("unknown-version", try framedJSON(unknownVersion)),
            ("trailing-bytes", validFrame + Data([0])),
            ("two-frames", validFrame + validFrame),
            ("unknown-operation", try framedJSON(validPayload.merging([
                "operation": ["unknown": [:]]
            ]) { _, new in new })),
            ("non-finite-brightness", framed(Data(
                "{\"version\":1,\"requestID\":{\"rawValue\":\"non-finite\"},\"operation\":{\"set\":{\"_0\":{\"rawValue\":1e999}}},\"deadline\":{\"remainingNanoseconds\":2000000000}}".utf8
            )))
        ]

        for (name, input) in malformedInputs {
            let harness = try ProcessHarness()
            let result = await harness.run(input: input, timeout: .seconds(2))
            XCTAssertEqual(result.termination, .exited, name)
            XCTAssertEqual(result.exitStatus, EX_OK, name)
            XCTAssertTrue(result.cleanupVerified, name)
            XCTAssertLessThanOrEqual(result.stdout.count, 64 * 1024, name)
            XCTAssertLessThanOrEqual(result.stderr.count, 64 * 1024, name)
            XCTAssertTrue(result.stderr.isEmpty, name)
            XCTAssertEqual(
                try FramedJSONCodec().decode(BacklightOperationResult.self, from: result.stdout),
                .failure(primary: .protocolViolation, restoration: .notRequired),
                name
            )
            XCTAssertEqual(try harness.currentValue(), try NormalizedBacklightValue(0.37), name)
            XCTAssertTrue(try harness.journalEntries().filter { $0.processRole == .writer }.isEmpty, name)
        }

        let extraOutputHarness = try ProcessHarness(faultActions: [.malformedOutput])
        let extraOutputRequest = try extraOutputHarness.makeRequest(
            requestID: "extra-writer-stdout",
            operation: .read
        )
        let writerResult = await extraOutputHarness.runWriter(
            input: try FramedJSONCodec().encode(extraOutputRequest),
            timeout: .seconds(2)
        )
        XCTAssertEqual(writerResult.termination, .exited)
        XCTAssertEqual(writerResult.exitStatus, EX_OK)
        XCTAssertTrue(writerResult.cleanupVerified)
        XCTAssertLessThanOrEqual(writerResult.stdout.count, 64 * 1024)
        XCTAssertLessThanOrEqual(writerResult.stderr.count, 64 * 1024)
        XCTAssertTrue(writerResult.stderr.isEmpty)
        XCTAssertThrowsError(
            try FramedJSONCodec().decode(BacklightOperationResult.self, from: writerResult.stdout)
        ) { error in
            XCTAssertEqual(error as? FramedJSONError, .trailingBytes)
        }
        XCTAssertEqual(try extraOutputHarness.currentValue(), try NormalizedBacklightValue(0.37))
        XCTAssertTrue(try extraOutputHarness.journalEntries().filter { $0.processRole == .writer }.isEmpty)
    }

    private func replacing(
        _ object: [String: Any],
        keyPath: [String],
        with value: Any
    ) -> [String: Any] {
        guard let key = keyPath.first else { return object }
        var copy = object
        if keyPath.count == 1 {
            copy[key] = value
            return copy
        }
        let nested = copy[key] as? [String: Any] ?? [:]
        copy[key] = replacing(
            nested,
            keyPath: Array(keyPath.dropFirst()),
            with: value
        )
        return copy
    }

    private func framed(_ payload: Data) -> Data {
        let length = UInt32(payload.count)
        return Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff)
        ]) + payload
    }

    private func framedJSON(_ object: Any) throws -> Data {
        framed(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    func testProcessEscapeAttemptsAreContainedAfterWriterRootExits() async throws {
        for (name, fault) in [
            ("forked-child", FakeBacklightFaultAction.forkSleepingChild),
            ("setsid-child", FakeBacklightFaultAction.attemptSetsid)
        ] {
            let harness = try ProcessHarness(faultActions: [fault])
            let request = try harness.makeRequest(
                requestID: "escape-\(name)",
                operation: .read
            )
            let started = ContinuousClock.now
            let result = await harness.runWriter(
                input: try FramedJSONCodec().encode(request),
                timeout: .seconds(4)
            )

            XCTAssertLessThan(started.duration(to: .now), .seconds(5), name)
            XCTAssertEqual(result.termination, .exited, name)
            XCTAssertEqual(result.exitStatus, EX_OK, name)
            XCTAssertTrue(result.cleanupVerified, name)
            XCTAssertTrue(result.stderr.isEmpty, name)
            XCTAssertEqual(
                try FramedJSONCodec().decode(BacklightOperationResult.self, from: result.stdout),
                .failure(primary: .protocolViolation, restoration: .notRequired),
                name
            )
            let descendantEntries = try harness.journalEntries().filter {
                $0.requestID == request.requestID && $0.processRole == .writer
            }
            let descendantPID = try XCTUnwrap(descendantEntries.last?.processID, name)
            XCTAssertNotEqual(descendantPID, result.rootPID, name)
            XCTAssertTrue(processIsGoneOrZombie(descendantPID), "\(name): PID \(descendantPID) survived")
            XCTAssertEqual(try harness.currentValue(), try NormalizedBacklightValue(0.37), name)
        }
    }

    private func processIsGoneOrZombie(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == -1 { return errno == ESRCH }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        return size <= 0 || info.pbi_status == UInt32(SZOMB)
    }

    func testStageTimeoutMatrixIsContainedAndReportsRestorationCertainty() throws {
        for stage in [
            BacklightStage.captureOriginal,
            .write,
            .writeReadback,
            .restore,
            .restoreReadback
        ] {
            let harness = try ProcessHarness(initialValue: 0.37, pausedAt: stage)
            let request = try harness.makeRequest(
                requestID: "stage-timeout-\(stage.rawValue)",
                operation: .set(try NormalizedBacklightValue(0.5)),
                deadlineNanoseconds: 1_500_000_000
            )
            let started = ContinuousClock.now
            let scenario = try harness.startScenario(
                input: try FramedJSONCodec().encode(request),
                outerTimeout: .seconds(5)
            )

            let processResult = try scenario.finish()
            let elapsed = started.duration(to: .now)
            XCTAssertLessThan(elapsed, .seconds(5), "stage=\(stage.rawValue)")
            XCTAssertEqual(processResult.termination, .exited, "stage=\(stage.rawValue)")
            let result = try FramedJSONCodec().decode(
                BacklightOperationResult.self,
                from: processResult.stdout
            )
            let entries = try scenario.journalEntries()
                .filter { $0.processRole == .writer }

            switch stage {
            case .captureOriginal:
                XCTAssertEqual(
                    result,
                    .failure(
                        primary: .timedOut(stage: .captureOriginal),
                        restoration: .notRequired
                    )
                )
                XCTAssertFalse(entries.contains { $0.operationCategory == .set })
                XCTAssertFalse(entries.contains { $0.operationCategory == .restore })
                XCTAssertEqual(try scenario.currentValue(), try NormalizedBacklightValue(0.37))
            case .write:
                XCTAssertEqual(
                    result,
                    .failure(
                        primary: .timedOut(stage: .write),
                        restoration: .verified(try NormalizedBacklightValue(0.37))
                    )
                )
                XCTAssertFalse(entries.contains { $0.operationCategory == .set })
                XCTAssertTrue(entries.contains { $0.operationCategory == .restore })
                XCTAssertEqual(try scenario.currentValue(), try NormalizedBacklightValue(0.37))
            case .writeReadback:
                XCTAssertEqual(
                    result,
                    .failure(
                        primary: .timedOut(stage: .writeReadback),
                        restoration: .verified(try NormalizedBacklightValue(0.37))
                    )
                )
                XCTAssertTrue(entries.contains { $0.operationCategory == .set })
                XCTAssertTrue(entries.contains { $0.operationCategory == .restore })
                XCTAssertEqual(try scenario.currentValue(), try NormalizedBacklightValue(0.37))
            case .restore:
                XCTAssertEqual(
                    result,
                    .failure(primary: .restorationFailed, restoration: .failed)
                )
                XCTAssertFalse(entries.contains { $0.operationCategory == .restore })
                XCTAssertEqual(try scenario.currentValue(), try NormalizedBacklightValue(0.5))
            case .restoreReadback:
                XCTAssertEqual(
                    result,
                    .failure(primary: .restorationUncertain, restoration: .uncertain)
                )
                XCTAssertTrue(entries.contains { $0.operationCategory == .restore })
                XCTAssertEqual(try scenario.currentValue(), try NormalizedBacklightValue(0.37))
            }
            try scenario.assertNoOwnedProcessesRemain()
        }
    }

    func testControllerSignalsLeaveSupervisorToRestoreOriginalValue() throws {
        for signal in [SIGINT, SIGTERM, SIGABRT, SIGKILL] {
            let harness = try ProcessHarness(initialValue: 0.37, pausedAt: .writeReadback)
            let request = try harness.makeRequest(
                requestID: "controller-signal-\(signal)",
                operation: .set(try NormalizedBacklightValue(0.5))
            )
            let scenario = try harness.startScenario(
                input: try FramedJSONCodec().encode(request),
                outerTimeout: .seconds(5)
            )

            try scenario.waitForHangBarrier(
                stage: .writeReadback,
                requestID: request.requestID
            )
            try scenario.signalOwnedRole(.controller, signal)
            let result = try scenario.finish()

            XCTAssertEqual(result.termination, .signaled(signal), "signal=\(signal)")
            XCTAssertEqual(
                try scenario.currentValue(),
                try NormalizedBacklightValue(0.37),
                "signal=\(signal)"
            )
            let operationCategories = try scenario.journalEntries()
                .filter { $0.processRole == .writer }
                .map(\.operationCategory)
            XCTAssertTrue(operationCategories.contains(.restore), "signal=\(signal)")
            XCTAssertEqual(operationCategories.last, .read, "signal=\(signal)")
            try scenario.assertNoOwnedProcessesRemain()
        }
    }

    func testWriterSignalsRestoreOriginalValue() throws {
        for signal in [SIGINT, SIGTERM, SIGABRT, SIGKILL] {
            let harness = try ProcessHarness(initialValue: 0.37, pausedAt: .writeReadback)
            let request = try harness.makeRequest(
                requestID: "writer-signal-\(signal)",
                operation: .set(try NormalizedBacklightValue(0.5))
            )
            let scenario = try harness.startScenario(
                input: try FramedJSONCodec().encode(request),
                outerTimeout: .seconds(5)
            )

            try scenario.waitForHangBarrier(
                stage: .writeReadback,
                requestID: request.requestID
            )
            try scenario.signalOwnedRole(.writer, signal)
            let result = try scenario.finish()

            XCTAssertEqual(result.termination, .exited, "signal=\(signal)")
            XCTAssertEqual(
                try FramedJSONCodec().decode(BacklightOperationResult.self, from: result.stdout),
                .failure(
                    primary: .writerFailed,
                    restoration: .verified(try NormalizedBacklightValue(0.37))
                ),
                "signal=\(signal)"
            )
            XCTAssertEqual(
                try scenario.currentValue(),
                try NormalizedBacklightValue(0.37),
                "signal=\(signal)"
            )
            try scenario.assertNoOwnedProcessesRemain()
        }
    }
}
